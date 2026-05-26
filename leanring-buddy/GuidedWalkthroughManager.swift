//
//  GuidedWalkthroughManager.swift
//  leanring-buddy
//
//  "Clicky Coach" — the guided walkthrough feature. Instead of pointing at one
//  thing once, Clicky can break a task into an ordered sequence of on-screen
//  steps, point at the first step, watch the screen as the user works, and
//  automatically advance to the next step when it detects the current one is
//  done. This file owns the walkthrough's plan model, observable state, and the
//  pure parsers that turn Claude's tagged responses into structured data.
//
//  The orchestration (capturing screenshots, calling Claude to locate each step
//  and to check completion, and driving the cursor) lives in CompanionManager,
//  which already owns those collaborators. This manager is the state + the
//  parsing logic, kept pure so it can be unit tested without any UI or network.
//

import Foundation

// MARK: - Plan Model

/// A single concrete on-screen action in a guided walkthrough.
struct WalkthroughStep: Equatable, Identifiable {
    /// 1-based position in the walkthrough, as authored by Claude.
    let stepNumber: Int
    /// The instruction shown in the HUD and spoken aloud (short, imperative).
    let instruction: String
    /// A 1-3 word label naming the UI element this step concerns. Used when
    /// asking Claude to locate the element on the current screen.
    let targetLabel: String

    var id: Int { stepNumber }
}

/// An ordered set of steps plus an optional human-readable title.
struct WalkthroughPlan: Equatable {
    let title: String?
    let steps: [WalkthroughStep]
}

/// The result of stripping a walkthrough plan out of a Claude response: the
/// parsed plan (if any) and the response text with the plan block removed so
/// the remaining prose can still be spoken/parsed for a [POINT:] tag.
struct WalkthroughParseResult: Equatable {
    let plan: WalkthroughPlan?
    let remainingText: String
}

// MARK: - Walkthrough Lifecycle State

/// The current phase of an active walkthrough, used to drive the HUD copy.
enum WalkthroughPhase: Equatable {
    /// Figuring out where the current step's element is on screen.
    case locating
    /// Pointing at the current step and waiting for the user to do it.
    case watching
    /// The current step was detected as done; moving to the next one.
    case advancing
    /// All steps finished successfully.
    case completed
}

// MARK: - Manager

@MainActor
final class GuidedWalkthroughManager: ObservableObject {
    /// Whether a walkthrough is currently running. Observed by the HUD and panel.
    @Published private(set) var isActive: Bool = false
    /// The plan being walked through, or nil when inactive.
    @Published private(set) var plan: WalkthroughPlan?
    /// The 0-based index of the step the user is currently on.
    @Published private(set) var currentStepIndex: Int = 0
    /// The current phase, used for HUD status text.
    @Published private(set) var phase: WalkthroughPhase = .locating

    /// The step the user is currently on, or nil when inactive / out of range.
    var currentStep: WalkthroughStep? {
        guard let plan, currentStepIndex >= 0, currentStepIndex < plan.steps.count else {
            return nil
        }
        return plan.steps[currentStepIndex]
    }

    var totalStepCount: Int { plan?.steps.count ?? 0 }

    /// 0.0–1.0 completion fraction, for the HUD progress bar.
    var progressFraction: Double {
        guard totalStepCount > 0 else { return 0 }
        if phase == .completed { return 1.0 }
        return Double(currentStepIndex) / Double(totalStepCount)
    }

    // MARK: - Lifecycle

    func begin(plan: WalkthroughPlan) {
        self.plan = plan
        self.currentStepIndex = 0
        self.phase = .locating
        self.isActive = true
    }

    func setPhase(_ newPhase: WalkthroughPhase) {
        phase = newPhase
    }

    /// Advances to the next step. Returns true if there is a next step, or false
    /// when the walkthrough has just finished its final step.
    @discardableResult
    func advanceToNextStep() -> Bool {
        guard let plan else { return false }
        if currentStepIndex + 1 < plan.steps.count {
            currentStepIndex += 1
            phase = .locating
            return true
        }
        phase = .completed
        return false
    }

    /// Marks the walkthrough complete but keeps `isActive` true so the HUD can
    /// show a brief "done" celebration. Call `cancel()` afterward to dismiss it.
    func finish() {
        phase = .completed
    }

    func cancel() {
        isActive = false
        plan = nil
        currentStepIndex = 0
        phase = .locating
    }

    // MARK: - Prompts (used by CompanionManager to drive the walkthrough)

    /// Appended to the main companion prompt. Tells Claude when and how to emit
    /// a walkthrough plan so multi-step "how do I…" tasks become guided.
    static let planInstruction = """

    guided walkthroughs:
    when the user asks how to do something that takes several concrete on-screen actions in a row (like "how do i commit and push", "set up dark mode", "export this video"), don't just point at the first thing — lay out the whole sequence as a guided walkthrough so you can coach them step by step.

    to do that, append a walkthrough block at the very end of your response, after your spoken intro. format exactly:

    [WALKTHROUGH: short title of the task]
    1) short imperative instruction | element label
    2) short imperative instruction | element label
    3) short imperative instruction | element label
    [/WALKTHROUGH]

    rules for the block:
    - each line is: step number, close paren, the instruction, a pipe, then a 1-3 word label naming the on-screen element for that step.
    - keep instructions short and spoken-friendly (a sentence at most). the element label is what you'd point at on screen.
    - only emit a walkthrough when there are at least two real steps and they happen on screen. for a single action, just use a normal [POINT:] tag instead. for pure knowledge questions, use neither.
    - your spoken intro before the block should be one short warm sentence like "sure, here's how — i'll walk you through it." do not read the steps aloud; the walkthrough handles that.
    - do not add a [POINT:] tag when you emit a walkthrough.
    """

    /// System prompt for locating the current step's element on a fresh
    /// screenshot. Claude returns just a [POINT:] tag.
    static func locatePrompt(forStep step: WalkthroughStep, totalSteps: Int) -> String {
        return """
        you're clicky, coaching the user through a task one step at a time. you can see their current screen. the user is on step \(step.stepNumber) of \(totalSteps): "\(step.instruction)". the element to point at is the "\(step.targetLabel)".

        find that element on the current screen and point at it. respond with ONLY a coordinate tag, nothing else.

        format: [POINT:x,y:label] using the screenshot's pixel dimensions as the coordinate space, origin (0,0) at top-left, x rightward, y downward. if you genuinely cannot find the element on this screen, respond [POINT:none].
        """
    }

    /// System prompt for checking whether the current step is complete on a
    /// fresh screenshot. Claude returns [STATUS:done] or [STATUS:waiting].
    static func watchPrompt(forStep step: WalkthroughStep, totalSteps: Int) -> String {
        return """
        you're clicky, watching the user's screen while they complete a task step by step. the current step is step \(step.stepNumber) of \(totalSteps): "\(step.instruction)".

        look at the current screen and decide whether the user has COMPLETED this specific step yet. be generous — if the screen clearly shows the result of doing this step (a panel opened, a field filled, a menu shown), it's done.

        respond with ONLY one tag, nothing else:
        - [STATUS:done] if the step looks complete
        - [STATUS:waiting] if they still need to do it
        """
    }

    // MARK: - Parsing (pure, unit-tested)

    /// Extracts a `[WALKTHROUGH: …] … [/WALKTHROUGH]` block from a Claude
    /// response and returns the parsed plan plus the response text with the
    /// block removed. When no valid block is present, `plan` is nil and
    /// `remainingText` is the original text (trimmed).
    static func parseWalkthroughPlan(from responseText: String) -> WalkthroughParseResult {
        let openPattern = #"\[WALKTHROUGH(?::\s*([^\]]*))?\]"#
        let closeMarker = "[/WALKTHROUGH]"

        guard let openRegex = try? NSRegularExpression(pattern: openPattern, options: [.caseInsensitive]),
              let openMatch = openRegex.firstMatch(
                in: responseText,
                range: NSRange(responseText.startIndex..., in: responseText)
              ),
              let openRange = Range(openMatch.range, in: responseText) else {
            return WalkthroughParseResult(
                plan: nil,
                remainingText: responseText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        // Title is the optional capture group after the colon.
        var title: String? = nil
        if openMatch.numberOfRanges >= 2, let titleRange = Range(openMatch.range(at: 1), in: responseText) {
            let candidate = String(responseText[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty { title = candidate }
        }

        // Find the closing marker after the opening tag.
        guard let closeRange = responseText.range(of: closeMarker, range: openRange.upperBound..<responseText.endIndex) else {
            return WalkthroughParseResult(
                plan: nil,
                remainingText: responseText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let innerText = String(responseText[openRange.upperBound..<closeRange.lowerBound])
        let steps = parseStepLines(from: innerText)

        // Build the remaining text by removing the whole block (open tag → close marker).
        var remaining = responseText
        remaining.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
        let cleanedRemaining = remaining.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !steps.isEmpty else {
            return WalkthroughParseResult(plan: nil, remainingText: cleanedRemaining)
        }

        return WalkthroughParseResult(
            plan: WalkthroughPlan(title: title, steps: steps),
            remainingText: cleanedRemaining
        )
    }

    /// Parses the step lines inside a walkthrough block. Each step looks like
    /// `1) do the thing | element label`. The number prefix and pipe-delimited
    /// label are both tolerant of extra whitespace and alternate separators
    /// (`.`, `)`, `:`). Lines that don't look like steps are ignored.
    static func parseStepLines(from innerText: String) -> [WalkthroughStep] {
        var steps: [WalkthroughStep] = []
        let lineStripPattern = #"^\s*(\d+)\s*[\).:\-]\s*(.+)$"#
        guard let lineRegex = try? NSRegularExpression(pattern: lineStripPattern, options: []) else {
            return steps
        }

        for rawLine in innerText.split(whereSeparator: { $0.isNewline }) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            guard let match = lineRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let numberRange = Range(match.range(at: 1), in: line),
                  let bodyRange = Range(match.range(at: 2), in: line),
                  let stepNumber = Int(line[numberRange]) else {
                continue
            }

            let body = String(line[bodyRange]).trimmingCharacters(in: .whitespaces)

            // Split instruction and label on the first pipe. If there's no pipe,
            // reuse the instruction as the label so locating still has something.
            let instruction: String
            let label: String
            if let pipeIndex = body.firstIndex(of: "|") {
                instruction = String(body[..<pipeIndex]).trimmingCharacters(in: .whitespaces)
                label = String(body[body.index(after: pipeIndex)...]).trimmingCharacters(in: .whitespaces)
            } else {
                instruction = body
                label = body
            }

            guard !instruction.isEmpty else { continue }
            steps.append(WalkthroughStep(
                stepNumber: stepNumber,
                instruction: instruction,
                targetLabel: label.isEmpty ? instruction : label
            ))
        }

        return steps
    }

    /// Returns true when a watch response indicates the current step is done.
    /// Tolerant of surrounding text and case.
    static func parseStepIsComplete(from responseText: String) -> Bool {
        let lowercased = responseText.lowercased()
        if lowercased.contains("[status:done]") { return true }
        if lowercased.contains("[status:waiting]") { return false }
        // Fall back to a looser check so a slightly off-format reply still works.
        return lowercased.contains("status:done") || lowercased.contains("step is done")
    }
}
