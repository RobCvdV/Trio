import Foundation

/// Unified payload Trio exports for the **Diabetics Advisor** Mac app: therapy settings +
/// recent time-series + algorithm output, in one JSON pushed to the user's private CloudKit.
///
/// This struct is mirrored verbatim in the Diabetics Advisor Mac app
/// (`~/Dev/diabetics-advisor-ai/Sources/Shared/AdvisorExport.swift`). Keep both in sync and
/// bump `schemaVersion` on breaking changes. Glucose-domain values are exported in mmol/L.
struct AdvisorExport: Codable {
    var schemaVersion: Int = 1
    var capturedAt: Date
    var appVersion: String?
    var glucoseUnit: String = "mmol/L"

    var settings: Settings
    var glucose: [GlucosePoint] = []
    var carbs: [CarbPoint] = []
    var insulin: [InsulinPoint] = []
    var determinations: [DeterminationPoint] = []

    struct SchedulePoint: Codable { let time: String; let value: Double }
    struct TargetPoint: Codable { let time: String; let low: Double; let high: Double }

    struct Settings: Codable {
        var targets: [TargetPoint] = []
        var basal: [SchedulePoint] = []
        var carbRatios: [SchedulePoint] = []
        var isf: [SchedulePoint] = []
        var maxIOB: Double?
        var maxCOB: Double?
        var maxBolus: Double?
        var maxBasal: Double?
        var dia: Double?
        var insulinPeak: Double?
        var extras: [String: String] = [:]
    }

    struct GlucosePoint: Codable { let date: Date; let value: Double; let direction: String? }
    struct CarbPoint: Codable { let date: Date; let carbs: Double; let fat: Double?; let protein: Double? }

    struct InsulinPoint: Codable {
        enum Kind: String, Codable { case bolus, smb, tempBasal, suspend }
        let date: Date
        let kind: Kind
        let units: Double?
        let rate: Double?
        let durationMin: Int?
    }

    struct DeterminationPoint: Codable {
        let date: Date
        let iob: Double?
        let cob: Double?
        let bg: Double?
        let isf: Double?
        let target: Double?
        let recommendedRate: Double?
        let recommendedBolus: Double?
        let reason: String?
        let predBGs: PredBGs?
    }

    struct PredBGs: Codable {
        let iob: [Double]?
        let cob: [Double]?
        let uam: [Double]?
        let zt: [Double]?
    }
}
