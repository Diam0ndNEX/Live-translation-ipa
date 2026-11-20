import Foundation

extension SampleHandler {
    /// 2.5.1: when the Legacy head start must not run. Before 2.5.1 any reduced performance tier (also Fair) held it.
    func headStartHeld(_ cfg: Config) -> Bool {
        let thermal = ProcessInfo.processInfo.thermalState
        return ProcessInfo.processInfo.isLowPowerModeEnabled || thermal == .serious || thermal == .critical ||
            cfg.pressure == true || cfg.smartCool == true || cfg.confirmationBurst == false
    }
}
