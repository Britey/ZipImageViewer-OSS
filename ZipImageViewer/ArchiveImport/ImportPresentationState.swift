import Foundation

/// Format-independent UI feedback. Fractions describe only the current stage.
struct ImportPresentationState: Equatable {
    enum Stage: Equatable {
        case preparingSource, copying, opening, waitingForPassword, extracting
        case compressing, preparingPreviews, preparingPages, cancelling, completed, failed

        var title: String {
            switch self {
            case .preparingSource: return "Preparing source…"
            case .copying: return "Copying archive…"
            case .opening: return "Opening archive…"
            case .waitingForPassword: return "Waiting for password"
            case .extracting: return "Extracting pages…"
            case .compressing: return "Compressing images…"
            case .preparingPreviews: return "Preparing previews…"
            case .preparingPages: return "Preparing pages…"
            case .cancelling: return "Cancelling…"
            case .completed: return "Ready to read"
            case .failed: return "Couldn’t open archive"
            }
        }
    }

    let stage: Stage
    let filename: String
    let progress: Double?
    let canCancel: Bool

    init(stage: Stage, filename: String, progress: Double? = nil, canCancel: Bool = false) {
        self.stage = stage
        self.filename = filename
        self.progress = progress.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
        self.canCancel = canCancel
    }

    static func from(coordinatorState: ArchiveImportCoordinator.State,
                     filename: String) -> ImportPresentationState? {
        switch coordinatorState {
        case .idle: return nil
        case .copying: return Self(stage: .copying, filename: filename, canCancel: true)
        case .opening: return Self(stage: .opening, filename: filename, canCancel: true)
        case .extracting(let fraction):
            return Self(stage: .extracting, filename: filename, progress: fraction, canCancel: true)
        case .compressing(let fraction):
            return Self(stage: .compressing, filename: filename, progress: fraction, canCancel: true)
        case .preparingPreviews(let fraction):
            return Self(stage: .preparingPreviews, filename: filename, progress: fraction, canCancel: true)
        case .finalizing: return Self(stage: .preparingPages, filename: filename, canCancel: true)
        case .awaitingPassword: return Self(stage: .waitingForPassword, filename: filename, canCancel: true)
        case .cancelling: return Self(stage: .cancelling, filename: filename)
        case .completed: return Self(stage: .completed, filename: filename)
        case .failed: return Self(stage: .failed, filename: filename)
        }
    }
}
