import AppKit

enum KeyboardLayouts {
    static let macRow:[KeySpec] = [KeySpec("Mac"),KeySpec("Esc",53),KeySpec("Tab",48),KeySpec("Ctrl"),KeySpec("Option"),KeySpec("⌘"),KeySpec("Caps"),KeySpec("←",123),KeySpec("↓",125),KeySpec("↑",126),KeySpec("→",124),KeySpec("Menus")]
    static let bottom:[KeySpec] = [KeySpec("🌐"),KeySpec("fn / 123"),KeySpec("Emoji"),KeySpec("Space",49,6.6),KeySpec("fn / 123",nil,1.4),KeySpec("Hide",nil,1.6)]
    static let ipadLetters:[[KeySpec]] = [
        [KeySpec("Tab",48,1.3),KeySpec("q",12),KeySpec("w",13),KeySpec("e",14),KeySpec("r",15),KeySpec("t",17),KeySpec("y",16),KeySpec("u",32),KeySpec("i",34),KeySpec("o",31),KeySpec("p",35),KeySpec("⌫",51,1.3)],
        [KeySpec("Caps",nil,1.6),KeySpec("a",0),KeySpec("s",1),KeySpec("d",2),KeySpec("f",3),KeySpec("g",5),KeySpec("h",4),KeySpec("j",38),KeySpec("k",40),KeySpec("l",37),KeySpec("Return",36,2)],
        [KeySpec("Shift",nil,2.2),KeySpec("z",6),KeySpec("x",7),KeySpec("c",8),KeySpec("v",9),KeySpec("b",11),KeySpec("n",45),KeySpec("m",46),KeySpec(",",43),KeySpec(".",47),KeySpec("Shift",nil,1.4)],
        bottom,macRow
    ]
    static let numbers:[[KeySpec]] = [
        [KeySpec("Tab",48,1.3),KeySpec("1",18),KeySpec("2",19),KeySpec("3",20),KeySpec("4",21),KeySpec("5",23),KeySpec("6",22),KeySpec("7",26),KeySpec("8",28),KeySpec("9",25),KeySpec("0",29),KeySpec("⌫",51,1.3)],
        [KeySpec("Caps",nil,1.6),KeySpec("-",27),KeySpec("/",44),KeySpec(":",41,shift:true),KeySpec(";",41),KeySpec("(",25,shift:true),KeySpec(")",29,shift:true),KeySpec("$",21,shift:true),KeySpec("&",26,shift:true),KeySpec("@",19,shift:true),KeySpec("Return",36,2)],
        [KeySpec("#+=",nil,2.2),KeySpec(".",47),KeySpec(",",43),KeySpec("?",44,shift:true),KeySpec("!",18,shift:true),KeySpec("'",39),KeySpec("\"",39,shift:true),KeySpec("+",24,shift:true),KeySpec("=",24),KeySpec("_",27,shift:true),KeySpec("#+=",nil,1.4)],
        [KeySpec("🌐"),KeySpec("ABC"),KeySpec("Emoji"),KeySpec("Space",49,6.6),KeySpec("ABC",nil,1.4),KeySpec("Hide",nil,1.6)],macRow
    ]
    static let symbols:[[KeySpec]] = [
        [KeySpec("Tab",48,1.3),KeySpec("[",33),KeySpec("]",30),KeySpec("{",33,shift:true),KeySpec("}",30,shift:true),KeySpec("#",20,shift:true),KeySpec("%",23,shift:true),KeySpec("^",22,shift:true),KeySpec("*",28,shift:true),KeySpec("+",24,shift:true),KeySpec("=",24),KeySpec("⌫",51,1.3)],
        [KeySpec("Caps",nil,1.6),KeySpec("_",27,shift:true),KeySpec("\\",42),KeySpec("|",42,shift:true),KeySpec("~",50,shift:true),KeySpec("`",50),KeySpec("<",43,shift:true),KeySpec(">",47,shift:true),KeySpec("'",39),KeySpec("\"",39,shift:true),KeySpec("Return",36,2)],
        [KeySpec("123",nil,2.2),KeySpec(".",47),KeySpec(",",43),KeySpec("?",44,shift:true),KeySpec("!",18,shift:true),KeySpec("'",39),KeySpec("\"",39,shift:true),KeySpec("+",24,shift:true),KeySpec("=",24),KeySpec("_",27,shift:true),KeySpec("123",nil,1.4)],
        [KeySpec("🌐"),KeySpec("ABC"),KeySpec("Emoji"),KeySpec("Space",49,6.6),KeySpec("ABC",nil,1.4),KeySpec("Hide",nil,1.6)],macRow
    ]
}

enum TrafficLightKind:String,CaseIterable {
    case close = "Close", minimize = "Minimize", zoom = "Zoom"
    var color:NSColor {
        switch self {
        case .close: return NSColor(srgbRed:1,green:95/255,blue:87/255,alpha:1)
        case .minimize: return NSColor(srgbRed:254/255,green:188/255,blue:46/255,alpha:1)
        case .zoom: return NSColor(srgbRed:40/255,green:200/255,blue:64/255,alpha:1)
        }
    }
}
