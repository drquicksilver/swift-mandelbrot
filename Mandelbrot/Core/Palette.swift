import Foundation

struct ColourSettings: Equatable, Sendable {
    var palette = Palette.blueGold
    var density: Float = 64
    var offset: Float = 0
    var smooth = true
}

enum Palette: String, CaseIterable, Identifiable, Sendable {
    case blueGold = "blue-gold", fire, ice, ink, twilight, forest, orbit
    var id: String { rawValue }
    var title: String { rawValue.replacingOccurrences(of:"-",with:" ").capitalized }
    var stops: [UInt32] {
        switch self {
        case .blueGold: return [0x05162f,0x154b83,0x7bc7da,0xffe6a3,0xce782c,0x05162f]
        case .fire: return [0x160c24,0x780e35,0xd52c20,0xffa62b,0xfff0b2,0x160c24]
        case .ice: return [0x041b35,0x14597a,0x50c8d7,0xe5fff5,0x648cad,0x041b35]
        case .ink: return [0x080c15,0x536171,0xffffff,0x536171,0x080c15]
        case .twilight: return [0x131339,0x523679,0xa85389,0xf4b393,0x7288ba,0x131339]
        case .forest: return [0x072d2c,0x14795b,0x8ebd65,0xf3e7ac,0x997147,0x072d2c]
        case .orbit: return []
        }
    }
    func rgb(_ phase: Float) -> SIMD3<Float> {
        let t=phase-floor(phase)
        if self == .orbit {
            // Constant-lightness/chroma OKLab wheel; converted to display sRGB.
            let angle=t*2*Float.pi, a=0.10*cos(angle), b=0.10*sin(angle), l: Float=0.72
            let ll=pow(l+0.3963377774*a+0.2158037573*b,3)
            let mm=pow(l-0.1055613458*a-0.0638541728*b,3)
            let ss=pow(l-0.0894841775*a-1.2914855480*b,3)
            let linear=SIMD3<Float>(4.0767416621*ll-3.3077115913*mm+0.2309699292*ss,
                -1.2684380046*ll+2.6097574011*mm-0.3413193965*ss,
                -0.0041960863*ll-0.7034186147*mm+1.7076147010*ss)
            func encode(_ x: Float) -> Float { min(1,max(0,x <= 0.0031308 ? x*12.92 : 1.055*pow(x,1/2.4)-0.055)) }
            return SIMD3(encode(linear.x),encode(linear.y),encode(linear.z))
        }
        let position=t*Float(stops.count-1), index=Int(position), f=position-Float(index)
        func unpack(_ value: UInt32) -> SIMD3<Float> {
            SIMD3(Float((value>>16)&255),Float((value>>8)&255),Float(value&255))/255
        }
        return unpack(stops[index])*(1-f)+unpack(stops[index+1])*f
    }
    func lookupTable(count: Int = 1024) -> [UInt8] {
        (0..<count).flatMap { index -> [UInt8] in
            let rgb=rgb(Float(index)/Float(count))
            return [UInt8(rgb.x*255),UInt8(rgb.y*255),UInt8(rgb.z*255),255]
        }
    }
}
