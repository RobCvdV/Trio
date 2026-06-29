import Combine
import CloudKit
import CoreData
import Foundation
import Swinject

/// Snapshot of the last export attempt — surfaced in Settings so the user can confirm it works.
struct AdvisorSyncStatus: Equatable {
    var date: Date
    var success: Bool
    var message: String
}

enum AdvisorSyncError: Error {
    case iCloudUnavailable

    var message: String {
        switch self {
        case .iCloudUnavailable:
            return String(localized: "iCloud account not available. Sign in to iCloud on this device and enable iCloud Drive.")
        }
    }
}

/// Exports the user's settings + recent treatment/glucose data to the **Diabetics Advisor**
/// Mac app, via the user's private CloudKit database. Runs in the background: pushes shortly
/// after each loop completes (debounced) and once at launch. Read-only w.r.t. Trio's data.
protocol AdvisorSyncManager {
    /// Fire-and-forget background sync (loop subscription + launch).
    func syncNow()
    /// Run a sync and return the outcome — used by the manual "Sync now" button in Settings.
    @discardableResult func syncAndReport() async -> AdvisorSyncStatus
    /// The most recent sync outcome, if any.
    var lastStatus: AdvisorSyncStatus? { get }
}

final class BaseAdvisorSyncManager: AdvisorSyncManager, Injectable {
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var storage: FileStorage!
    @Injected() private var apsManager: APSManager!
    @Injected() private var pumpHistoryStorage: PumpHistoryStorage!

    private let coreData = CoreDataStack.shared
    private let containerID = "iCloud.com.robcoenen.diabeticsadvisor"
    private let recordType = "AdvisorExport"
    private let recordName = "current-advisor-export"

    /// How many days of time-series to export — wide enough for multi-week pattern analysis.
    private let windowDays = 14
    private var windowStart: Date { Date().addingTimeInterval(-Double(windowDays) * 24 * 3600) }
    /// Predicate for entities keyed on a `date` attribute (GlucoseStored, CarbEntryStored).
    private var windowPredicate: NSPredicate { NSPredicate(format: "date >= %@", windowStart as NSDate) }

    private let queue = DispatchQueue(label: "BaseAdvisorSyncManager.queue", qos: .background)
    private var subscriptions = Set<AnyCancellable>()

    private let statusLock = NSLock()
    private var _lastStatus: AdvisorSyncStatus?
    var lastStatus: AdvisorSyncStatus? {
        statusLock.lock(); defer { statusLock.unlock() }
        return _lastStatus
    }

    init(resolver: Resolver) {
        injectServices(resolver)
        subscribe()
    }

    private func subscribe() {
        // Push shortly after each loop, debounced so rapid updates coalesce.
        apsManager.lastLoopDateSubject
            .debounce(for: .seconds(20), scheduler: queue)
            .sink { [weak self] _ in self?.syncNow() }
            .store(in: &subscriptions)
        // And once shortly after launch — delayed so we never run on the critical launch
        // path. Trio's loop/dosing startup must never wait on, or be affected by, our export.
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in self?.syncNow() }
    }

    func syncNow() {
        Task.detached(priority: .background) { [weak self] in
            _ = await self?.performSync()
        }
    }

    @discardableResult
    func syncAndReport() async -> AdvisorSyncStatus {
        await performSync()
    }

    /// Builds and pushes the export, recording the outcome in `lastStatus`.
    @discardableResult
    private func performSync() async -> AdvisorSyncStatus {
        let status: AdvisorSyncStatus
        do {
            let export = try await buildExport()
            try await push(export)
            let msg = String(
                localized: "Pushed \(export.glucose.count) glucose, \(export.insulin.count) insulin, \(export.determinations.count) determinations"
            )
            debug(.service, "AdvisorSync: \(msg)")
            status = AdvisorSyncStatus(date: Date(), success: true, message: msg)
        } catch let error as AdvisorSyncError {
            warning(.service, "AdvisorSync: sync failed: \(error)")
            status = AdvisorSyncStatus(date: Date(), success: false, message: error.message)
        } catch {
            warning(.service, "AdvisorSync: sync failed: \(error)")
            status = AdvisorSyncStatus(date: Date(), success: false, message: (error as NSError).localizedDescription)
        }
        statusLock.lock(); _lastStatus = status; statusLock.unlock()
        return status
    }

    // MARK: - Build

    private func buildExport() async throws -> AdvisorExport {
        let prefs = settingsManager.preferences
        let pump = settingsManager.pumpSettings

        var settings = AdvisorExport.Settings()
        settings.targets = readTargets()
        settings.basal = readBasal()
        settings.carbRatios = readCarbRatios()
        settings.isf = readISF()
        settings.maxIOB = prefs.maxIOB.asDouble
        settings.maxCOB = prefs.maxCOB.asDouble
        settings.maxBolus = pump.maxBolus.asDouble
        settings.maxBasal = pump.maxBasal.asDouble
        settings.dia = pump.insulinActionCurve.asDouble
        settings.insulinPeak = prefs.insulinPeakTime.asDouble

        async let glucose = readGlucose()
        async let carbs = readCarbs()
        async let insulin = readInsulin()
        async let dets = readDeterminations()
        async let overrides = readOverrides()
        async let tempTargets = readTempTargets()

        var export = AdvisorExport(capturedAt: Date(), appVersion: Bundle.main.releaseVersionNumber, settings: settings)
        export.glucose = try await glucose
        export.carbs = try await carbs
        export.insulin = await insulin
        export.determinations = try await dets
        export.overrides = try await overrides
        export.tempTargets = try await tempTargets
        return export
    }

    // MARK: - Settings readers (converted to mmol/L)

    private func toMmol(_ value: Decimal, _ units: GlucoseUnits) -> Double {
        (units == .mgdL ? value.asMmolL : value).asDouble
    }

    private func hhmm(_ start: String) -> String { String(start.prefix(5)) }

    private func readTargets() -> [AdvisorExport.TargetPoint] {
        guard let t = storage.retrieve(OpenAPS.Settings.bgTargets, as: BGTargets.self) else { return [] }
        return t.targets.map { .init(time: hhmm($0.start), low: toMmol($0.low, t.units), high: toMmol($0.high, t.units)) }
    }

    private func readBasal() -> [AdvisorExport.SchedulePoint] {
        let basal = storage.retrieve(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self) ?? []
        return basal.map { .init(time: hhmm($0.start), value: $0.rate.asDouble) }
    }

    private func readCarbRatios() -> [AdvisorExport.SchedulePoint] {
        guard let cr = storage.retrieve(OpenAPS.Settings.carbRatios, as: CarbRatios.self) else { return [] }
        return cr.schedule.map { .init(time: hhmm($0.start), value: $0.ratio.asDouble) }
    }

    private func readISF() -> [AdvisorExport.SchedulePoint] {
        guard let isf = storage.retrieve(OpenAPS.Settings.insulinSensitivities, as: InsulinSensitivities.self) else { return [] }
        return isf.sensitivities.map { .init(time: hhmm($0.start), value: toMmol($0.sensitivity, isf.units)) }
    }

    // MARK: - Time-series readers

    private func readGlucose() async throws -> [AdvisorExport.GlucosePoint] {
        let ctx = coreData.newTaskContext()
        let result = try await coreData.fetchEntitiesAsync(
            ofType: GlucoseStored.self, onContext: ctx,
            predicate: windowPredicate, key: "date", ascending: true
        )
        return await ctx.perform {
            (result as? [GlucoseStored] ?? []).compactMap { g -> AdvisorExport.GlucosePoint? in
                guard let date = g.date else { return nil }
                return AdvisorExport.GlucosePoint(date: date, value: Int(g.glucose).asMmolL.asDouble, direction: g.direction)
            }
        }
    }

    private func readCarbs() async throws -> [AdvisorExport.CarbPoint] {
        let ctx = coreData.newTaskContext()
        let result = try await coreData.fetchEntitiesAsync(
            ofType: CarbEntryStored.self, onContext: ctx,
            predicate: windowPredicate, key: "date", ascending: true
        )
        return await ctx.perform {
            (result as? [CarbEntryStored] ?? []).compactMap { c -> AdvisorExport.CarbPoint? in
                guard let date = c.date else { return nil }
                return AdvisorExport.CarbPoint(date: date, carbs: c.carbs, fat: c.fat, protein: c.protein)
            }
        }
    }

    private func readInsulin() async -> [AdvisorExport.InsulinPoint] {
        let cutoff = windowStart
        let events = (try? await pumpHistoryStorage.getPumpHistory()) ?? []
        return events.compactMap { e -> AdvisorExport.InsulinPoint? in
            guard e.timestamp >= cutoff else { return nil }
            switch e.type {
            case .bolus:
                return .init(date: e.timestamp, kind: (e.isSMB == true) ? .smb : .bolus,
                             units: e.amount?.asDouble, rate: nil, durationMin: nil)
            case .smb:
                return .init(date: e.timestamp, kind: .smb, units: e.amount?.asDouble, rate: nil, durationMin: nil)
            case .tempBasal:
                return .init(date: e.timestamp, kind: .tempBasal, units: nil,
                             rate: e.rate?.asDouble, durationMin: e.durationMin ?? e.duration)
            case .pumpSuspend:
                return .init(date: e.timestamp, kind: .suspend, units: nil, rate: nil, durationMin: nil)
            default:
                return nil
            }
        }
    }

    private func readDeterminations() async throws -> [AdvisorExport.DeterminationPoint] {
        let ctx = coreData.newTaskContext()
        // OrefDetermination is keyed on `deliverAt` (it has no `date` attribute), so the generic
        // date predicates would throw an NSException during SQL generation. Filter on `deliverAt`.
        // fetchLimit is a generous safety cap (~21 days at one loop / 5 min).
        let predicate = NSPredicate(format: "deliverAt >= %@", windowStart as NSDate)
        let result = try await coreData.fetchEntitiesAsync(
            ofType: OrefDetermination.self, onContext: ctx,
            predicate: predicate, key: "deliverAt", ascending: true, fetchLimit: 6000
        )
        return await ctx.perform {
            (result as? [OrefDetermination] ?? []).compactMap { d -> AdvisorExport.DeterminationPoint? in
                guard let date = d.deliverAt else { return nil }
                return AdvisorExport.DeterminationPoint(
                    date: date,
                    iob: d.iob?.doubleValue,
                    cob: Double(d.cob),
                    bg: d.glucose.map { $0.doubleValue.asMmolFromMgdL },
                    isf: d.insulinSensitivity.map { $0.doubleValue.asMmolFromMgdL },
                    target: d.currentTarget.map { $0.doubleValue.asMmolFromMgdL },
                    recommendedRate: d.rate?.doubleValue,
                    recommendedBolus: d.insulinReq?.doubleValue,
                    // The reason string is verbose; truncate to keep the payload manageable.
                    reason: d.reason.map { String($0.prefix(240)) },
                    predBGs: nil
                )
            }
        }
    }

    private func readOverrides() async throws -> [AdvisorExport.OverridePoint] {
        let ctx = coreData.newTaskContext()
        let predicate = NSPredicate(format: "startDate >= %@", windowStart as NSDate)
        let result = try await coreData.fetchEntitiesAsync(
            ofType: OverrideRunStored.self, onContext: ctx,
            predicate: predicate, key: "startDate", ascending: true
        )
        return await ctx.perform {
            (result as? [OverrideRunStored] ?? []).compactMap { run -> AdvisorExport.OverridePoint? in
                guard let start = run.startDate else { return nil }
                let def = run.override
                let affectsISF = (def?.isf ?? false) || (def?.isfAndCr ?? false)
                let affectsCR = (def?.cr ?? false) || (def?.isfAndCr ?? false)
                return AdvisorExport.OverridePoint(
                    start: start,
                    end: run.endDate,
                    name: run.name ?? def?.name,
                    percentage: def?.percentage,
                    affectsISF: affectsISF,
                    affectsCR: affectsCR,
                    target: (run.target ?? def?.target).map { $0.doubleValue.asMmolFromMgdL }
                )
            }
        }
    }

    private func readTempTargets() async throws -> [AdvisorExport.TempTargetPoint] {
        let ctx = coreData.newTaskContext()
        let predicate = NSPredicate(format: "startDate >= %@", windowStart as NSDate)
        let result = try await coreData.fetchEntitiesAsync(
            ofType: TempTargetRunStored.self, onContext: ctx,
            predicate: predicate, key: "startDate", ascending: true
        )
        return await ctx.perform {
            (result as? [TempTargetRunStored] ?? []).compactMap { run -> AdvisorExport.TempTargetPoint? in
                guard let start = run.startDate else { return nil }
                return AdvisorExport.TempTargetPoint(
                    start: start,
                    end: run.endDate,
                    name: run.name ?? run.tempTarget?.name,
                    target: (run.target ?? run.tempTarget?.target).map { $0.doubleValue.asMmolFromMgdL }
                )
            }
        }
    }

    // MARK: - CloudKit push

    private func push(_ export: AdvisorExport) async throws {
        let container = CKContainer(identifier: containerID)
        guard (try? await container.accountStatus()) == .available else {
            throw AdvisorSyncError.iCloudUnavailable
        }
        let db = container.privateCloudDatabase
        let id = CKRecord.ID(recordName: recordName)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(export)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try data.write(to: tmp, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let record = (try? await db.record(for: id)) ?? CKRecord(recordType: recordType, recordID: id)
        record["payload"] = CKAsset(fileURL: tmp)
        record["capturedAt"] = export.capturedAt as NSDate
        _ = try await db.save(record)
    }
}

private extension Decimal {
    var asDouble: Double { (self as NSDecimalNumber).doubleValue }
}

private extension Double {
    /// Convert a mg/dL value (stored by the determination) to mmol/L.
    var asMmolFromMgdL: Double { self * 0.0555 }
}
