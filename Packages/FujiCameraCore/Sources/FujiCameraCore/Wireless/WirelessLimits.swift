public enum WirelessLimits {
  public static let savedReconnect: Duration = .seconds(30)
  public static let firstPairing: Duration = .seconds(90)
  public static let wifiReadiness: Duration = .seconds(15)

  /// Bounds the app's wait. iOS owns dismissal of its join prompt.
  public static let joinResult: Duration = .seconds(120)
  public static let tcpSetup: Duration = .seconds(15)
  public static let transactionInactivity: Duration = .seconds(30)
  public static let autoSaveRegistration: Duration = .seconds(120)
}
