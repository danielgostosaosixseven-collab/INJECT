import Foundation

enum DevicePatchService {
    static let operationQueue = DispatchQueue(label: "device.patch.operations", qos: .userInitiated)
    private static let transactionLock = NSRecursiveLock()

    static func apply(project: PatchProject) throws -> PatchTransactionReceipt {
        transactionLock.lock()
        defer { transactionLock.unlock() }

        let bundleIDs = orderedBundleIdentifiers(in: project)
        return try withResolvedContainers(bundleIDs: bundleIDs) { roots in
            try PatchTransaction.apply(
                project: project,
                backupRoot: try PatchProjectLibrary.backupRootURL(),
                containerResolver: { bundleID in
                    guard let root = roots[bundleID] else {
                        throw PatchPackageError.targetAppUnavailable(bundleID)
                    }
                    return root
                }
            )
        }
    }

    static func restore(
        receipt: PatchTransactionReceipt,
        allowModifiedPatchedFiles: Bool = false
    ) throws {
        transactionLock.lock()
        defer { transactionLock.unlock() }

        let bundleIDs = try PatchTransaction.requiredBundleIdentifiers(for: receipt)
        try withResolvedContainers(bundleIDs: bundleIDs) { roots in
            try PatchTransaction.restore(
                receipt: receipt,
                containerResolver: { bundleID in
                    guard let root = roots[bundleID] else {
                        throw PatchPackageError.targetAppUnavailable(bundleID)
                    }
                    return root
                },
                allowModifiedPatchedFiles: allowModifiedPatchedFiles
            )
        }
    }

    static func latestReceipt(projectID: UUID) -> PatchTransactionReceipt? {
        transactionLock.lock()
        defer { transactionLock.unlock() }
        guard let backupRoot = try? PatchProjectLibrary.backupRootURL() else { return nil }

        return PatchTransaction.latestReceipt(projectID: projectID, backupRoot: backupRoot)
    }

    struct RecoveryResult {
        var restoredIDs: Set<UUID> = []
        var remainingIDs: Set<UUID> = []
        var failures: [String] = []
        var restoredTransactions = 0
    }

    /// Discover every pending journal, including patches removed from the current catalog.
    static func pendingReceipts() -> [PatchTransactionReceipt] {
        transactionLock.lock()
        defer { transactionLock.unlock() }
        guard let root = try? PatchProjectLibrary.backupRootURL(),
              let projects = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
              ) else { return [] }
        var receipts: [PatchTransactionReceipt] = []
        for directory in projects {
            guard let id = UUID(uuidString: directory.lastPathComponent) else { continue }
            if let receipt = PatchTransaction.latestReceipt(projectID: id, backupRoot: root) {
                receipts.append(receipt)
            }
        }
        return receipts.sorted { $0.createdAt > $1.createdAt }
    }

    /// Remove journals and backups only after every pending original was restored.
    /// Used by the explicit "Resetar do zero" recovery action.
    static func discardResolvedJournals() {
        transactionLock.lock()
        defer { transactionLock.unlock() }
        guard let root = try? PatchProjectLibrary.backupRootURL() else { return }
        do {
            let entries = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            for entry in entries {
                try? FileManager.default.removeItem(at: entry)
            }
            log("recovery: resolved journals discarded by full reset")
        } catch {
            log("recovery: could not discard resolved journals: \(error.localizedDescription)")
        }
    }

    /// Restore all pending journals using worse_query direct access.
    static func restorePendingOriginals(reconnect: Bool, projectIDs: Set<UUID>? = nil) -> RecoveryResult {
        transactionLock.lock()
        defer { transactionLock.unlock() }
        var result = RecoveryResult()
        var blockedProjects: Set<UUID> = []
        var processedTransactions: Set<UUID> = []
        while true {
            let candidates = pendingReceipts().filter {
                (projectIDs == nil || projectIDs!.contains($0.projectID)) &&
                !blockedProjects.contains($0.projectID) && !processedTransactions.contains($0.id)
            }
            guard let receipt = candidates.first else { break }
            processedTransactions.insert(receipt.id)
            do {
                try restore(receipt: receipt, allowModifiedPatchedFiles: true)
                result.restoredTransactions += 1
                result.restoredIDs.insert(receipt.projectID)
            } catch {
                blockedProjects.insert(receipt.projectID)
                result.failures.append(error.localizedDescription)
                log("recovery: preserving failed journal \(receipt.id): \(error.localizedDescription)")
                break
            }
        }
        result.remainingIDs = Set(pendingReceipts().filter {
            projectIDs == nil || projectIDs!.contains($0.projectID)
        }.map(\.projectID))
        result.restoredIDs.subtract(result.remainingIDs)
        return result
    }

    static func forceOriginalForCurrentBackend(bundleID: String) throws {
        transactionLock.lock()
        defer { transactionLock.unlock() }
        guard let entry = FixedGameOriginalStore.directEntries.first(where: { $0.bundleID == bundleID }) else {
            throw PatchPackageError.restoreFailed
        }
        try withResolvedContainers(bundleIDs: [bundleID]) { roots in
            guard let root = roots[bundleID] else { throw PatchPackageError.restoreFailed }
            let target = try PatchPathValidator.resolveContainedTargetURL(relativePath: entry.relativePath, containerRoot: root)
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: staging) }
            try entry.data.write(to: staging, options: .atomic)
            _ = try FileReplacementService.replace(target: target, with: staging)
            guard try Data(contentsOf: target) == entry.data else { throw PatchPackageError.restoreFailed }
        }
    }

    static func verifyDirectFileAccess(bundleID: String) throws {
        guard WorseQueryAccess.isRequired else { throw PatchPackageError.targetAppUnavailable(bundleID) }
        try withResolvedContainers(bundleIDs: [bundleID]) { _ in () }
    }

    private static func orderedBundleIdentifiers(in project: PatchProject) -> [String] {
        project.allBundleIdentifiers
    }

    private static func withResolvedContainers<T>(
        bundleIDs: [String],
        operation: ([String: URL]) throws -> T
    ) throws -> T {
        var roots: [String: URL] = [:]
        var leases: [Int64] = []
        defer { leases.forEach { worse_query_release($0) } }

        for bundleID in bundleIDs {
            if WorseQueryAccess.isRequired && !ExploitSupportPolicy.gameBundleIDs.contains(bundleID) {
                throw PatchPackageError.targetAppUnavailable(bundleID)
            }
            guard let path = ContainerStore.resolveAppContainerPath(bundleID: bundleID),
                  ContainerStore.isApplicationContainerPath(path) else {
                throw PatchPackageError.targetAppUnavailable(bundleID)
            }
            roots[bundleID] = PatchPathValidator.canonicalFileURL(
                URL(fileURLWithPath: path, isDirectory: true)
            )
            if WorseQueryAccess.isRequired {
                let attempt = WorseQueryAccess.grantWithDiagnostics(path: path, bundleID: bundleID)
                guard let lease = attempt.handle else {
                    throw WorseQueryAccess.AccessFailure(codes: attempt.codes)
                }
                leases.append(lease)
                try GameFileAccessProbe.verify(containerRoot: roots[bundleID]!)
            }
        }
        return try operation(roots)
    }
}
