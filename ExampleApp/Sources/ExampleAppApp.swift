import SwiftUI

// 最小 SwiftUI 应用入口，仅用于产出一个可签名、可上传、可被 SLSA attest 的 .ipa。
@main
struct ExampleAppApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
