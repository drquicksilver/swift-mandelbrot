import SwiftUI

struct AcknowledgementsView: View {
  private var notice: String {
    guard let url = Bundle.main.url(forResource: "LICENSE", withExtension: "md"),
      let text = try? String(contentsOf: url, encoding: .utf8)
    else { return "The bundled BigInt licence notice could not be loaded." }
    return text
  }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text("BigInt 5.7.0").font(.headline)
        Text(
          "Arbitrary-precision integers by Attaswift contributors, used for deep-zoom coordinates and reference orbits."
        )
        Link(
          "BigInt source",
          destination: URL(string: "https://github.com/attaswift/BigInt/tree/v5.7.0")!)
        Text(notice).font(.caption).textSelection(.enabled)
        Divider()
        Text("Deep-zoom algorithms").font(.headline)
        Text(
          "Perturbation, critical-point rebasing and bilinear approximation follow the mathematical descriptions collected by Claude Heiland-Allen. The implementation was written for this app."
        )
        Link(
          "Deep zoom theory and practice",
          destination: URL(
            string: "https://mathr.co.uk/blog/2022-02-21_deep_zoom_theory_and_practice_again.html")!
        )
      }.frame(maxWidth: .infinity, alignment: .leading).padding()
    }.navigationTitle("Acknowledgements")
  }
}
