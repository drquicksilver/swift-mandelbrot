import Foundation
import Testing

@testable import MandelbrotCore

@Test func palettesAreFiniteCyclicAndOpaque() {
  for palette in Palette.allCases {
    #expect(palette.lookupTable().count == 4096)
    let a = palette.rgb(0)
    let b = palette.rgb(1)
    #expect(a == b)
    for i in 0..<1024 {
      let value = palette.rgb(Float(i) / 1024)
      for lane in 0..<3 { #expect(value[lane].isFinite && value[lane] >= 0 && value[lane] <= 1) }
    }
  }
}
