
import SwiftUI

struct GlobalHotkeySimple: View {
    @State private var message: String? = nil
    
    @State private var monitor: Any? = nil

    var body: some View {
        VStack {
            if let message {
                Text(message)
            } else {
                Text("Press on some keys!")
            }
        }
        .onAppear {
            self.monitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyUp, .keyDown]) { event in
                switch event.type {
                case .flagsChanged:
                    print("flagsChanged")
                    print(event.modifierFlags.rawValue)
                    self.message = "flagsChanged: \(event.modifierFlags)"
                
                case .keyDown:
                    print("key down")
                    print(event.keyCode.description)
                    self.message = "key down: \(event.charactersIgnoringModifiers, default: "unknown")"
                case .keyUp:
                    print("key up")
                    print(event.keyCode.description)
                    self.message = "key up: \(event.charactersIgnoringModifiers, default: "unknown")"

                default:
                    return
                }
            }
        }
        .onDisappear {
            guard let monitor = self.monitor else {return}
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
