import HaishinKit
@preconcurrency import Logboard
import RTCHaishinKit
import RTMPHaishinKit
import SRTHaishinKit
import SwiftUI

nonisolated let logger = LBLogger.with("com.haishinkit.HaishinApp")

@main
struct HaishinApp: App {
    @State private var preference = PreferenceViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(preference)
        }
    }

    init() {
        Task {
            await SessionBuilderFactory.shared.register(RTMPSessionFactory())
            await SessionBuilderFactory.shared.register(SRTSessionFactory())
            await SessionBuilderFactory.shared.register(HTTPSessionFactory())

            await RTCLogger.shared.setLevel(.debug)
            await SRTLogger.shared.setLevel(.debug)
        }
        LBLogger(kHaishinKitIdentifier).level = .debug
        LBLogger(kRTCHaishinKitIdentifier).level = .debug
        LBLogger(kRTMPHaishinKitIdentifier).level = .debug
        LBLogger(kSRTHaishinKitIdentifier).level = .debug
    }
}
