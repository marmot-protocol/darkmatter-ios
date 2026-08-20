import Foundation
import Testing
@testable import whitenoise_ios

@MainActor
struct VoiceMessageRecorderLifecycleTests {
    @Test func activeRecordingProtectionAllowsWritesWhileLockedUntilCompletion() {
        #expect(VoiceRecordingFileProtection.activeRecording == FileProtectionType.completeUnlessOpen)
        #expect(VoiceRecordingFileProtection.completedRecording == FileProtectionType.complete)
    }

    @Test func persistedWaveformBucketsWholeRecordingInsteadOfTailOnly() {
        var accumulator = VoiceRecordingWaveformAccumulator()
        let earlySamples = Array(repeating: CGFloat(0.95), count: MediaWaveformAnalyzer.sampleCount)
        let tailSamples = Array(repeating: CGFloat(0.10), count: MediaWaveformAnalyzer.sampleCount)
        for sample in earlySamples + tailSamples {
            accumulator.append(sample)
        }

        let persisted = accumulator.persistedSamples()

        #expect(persisted.count == MediaWaveformAnalyzer.sampleCount)
        #expect((persisted.first ?? 0) > 0.9)
        #expect((persisted.last ?? 1) < 0.2)
    }

    @Test func meteringTaskDoesNotRetainRecorderOwner() async {
        var recorder: VoiceMessageRecorder? = VoiceMessageRecorder()
        weak let weakRecorder = recorder

        recorder?.startMeteringForTesting()
        recorder = nil
        await Task.yield()

        #expect(weakRecorder == nil)
    }

    @Test func pendingHoldTaskDoesNotRetainRecorderOwner() async {
        var recorder: VoiceMessageRecorder? = VoiceMessageRecorder()
        weak let weakRecorder = recorder

        recorder?.beginPress { _ in }
        #expect(recorder?.isActive == true)

        recorder = nil
        await Task.yield()

        #expect(weakRecorder == nil)
    }

    @Test func cancelIfActiveStopsPendingPressBeforeRecorderStarts() {
        let recorder = VoiceMessageRecorder()

        recorder.beginPress { _ in }
        #expect(recorder.isActive)

        recorder.cancelIfActive()

        #expect(!recorder.isActive)
    }

    @Test func keyboardDismissalWaitsUntilRecordingActuallyStarted() {
        #expect(!VoiceMessageRecorder.RecordingState.idle.hasStartedRecording)
        #expect(!VoiceMessageRecorder.RecordingState.pressing.hasStartedRecording)
        #expect(VoiceMessageRecorder.RecordingState.recording(locked: false).hasStartedRecording)
        #expect(VoiceMessageRecorder.RecordingState.recording(locked: true).hasStartedRecording)
    }

}
