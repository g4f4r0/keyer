public enum DictationRecordingPolicy {
    public static let maximumDurationSeconds: Double = 15 * 60
    public static let warningLeadTimeSeconds: Double = 60

    public static var warningStartSeconds: Double {
        maximumDurationSeconds - warningLeadTimeSeconds
    }
}
