// `--test-tiles` checks for the help: every toolbar button has an icon and an
// explanation, and each gesture is its own line.

#if os(macOS)
  import Foundation

  extension TileDiagnostics {
    /// The help and the tooltips.  Every toolbar button explains itself, in the
    /// same words in both places, and the gestures are one idea per line: the
    /// paragraph this replaced ran "Drag to move. ... Shift-drag to frame a
    /// region." together, which reads as though a plain drag should frame one.
    static func checkHelpCoverage() throws {
      var explanations: Set<String> = []
      for action in ToolbarAction.allCases {
        try require(!action.icon.isEmpty, "\(action) has no icon")
        try require(!action.title.isEmpty, "\(action) has no title")
        try require(
          action.explanation.count > 12 && action.explanation.hasSuffix("."),
          "\(action) has no tooltip worth reading: \"\(action.explanation)\"")
        try require(
          explanations.insert(action.explanation).inserted,
          "\(action) repeats another button's tooltip")
        if let command = action.command {
          try require(
            !command.binding.isEmpty, "\(action)'s shortcut \(command) has no binding to show")
        }
      }
      // The help is built from the same list, so a button cannot appear in the
      // toolbar without a row explaining it.
      try require(
        Set(HelpContent.toolbar) == Set(ToolbarAction.allCases),
        "The help does not cover every toolbar button")

      // One idea per line, and the pan and the frame are separate ideas.
      let gestures = HelpContent.gestures
      try require(gestures.count >= 5, "The gestures are too thin: \(gestures.count) lines")
      for line in gestures {
        try require(!line.icon.isEmpty, "A gesture line has no icon: \(line.text)")
        try require(
          line.text.hasSuffix(".") && line.text.dropLast().allSatisfy({ $0 != "." }),
          "A gesture line runs two sentences together: \"\(line.text)\"")
      }
      try require(
        gestures.contains { $0.text.lowercased().hasPrefix("drag to move") },
        "The help no longer says that a plain drag moves the view")
      #if os(macOS)
        let framing = gestures.contains {
          $0.text.contains("Shift") && $0.text.lowercased().contains("frame")
        }
        let conflated = gestures.contains {
          $0.text.lowercased().hasPrefix("drag to move")
            && $0.text.lowercased().contains("frame")
        }
        try require(
          framing && !conflated, "Framing a region is not described apart from panning")
      #endif
      try require(
        gestures.contains { $0.text.lowercased().contains("crosshair") },
        "The help does not explain the crosshair")

      // The shortcuts come last, and only where there is a keyboard.
      try require(
        HelpContent.keyboard.allSatisfy { !$0.title.isEmpty && !$0.binding.isEmpty },
        "A keyboard command has no title or no binding")
      try require(
        HelpContent.keyboard.contains(.swapJulia) && !HelpContent.keyboard.contains(.benchmark),
        "The keyboard list shows the wrong commands")
      try require(
        HelpContent.showsKeyboard(hardwareKeyboard: true),
        "The shortcuts are hidden where there is a keyboard")
      #if !os(macOS)
        try require(
          !HelpContent.showsKeyboard(hardwareKeyboard: false),
          "The shortcuts are shown with no keyboard attached")
      #endif
    }
  }
#endif
