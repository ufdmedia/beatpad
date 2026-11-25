import Foundation
import AVFoundation
import Accelerate
import Darwin
import IOKit
import CoreAudio

// MARK: - Tuning

let fftSize = 2048
let hopSize = 256
// Correct the detector bias to center kick times on the true onsets.
let onsetBias = -0.010514
let kickDuration = 0.090
let kickFloorHz = 70.0
let kickDiveHz = 230.0
let kickDiveDecay = 0.015
let kickEnvelopeDecay = 0.040
let kickBaseLevel = 0.45
let kickStrengthLevel = 0.55
let accentDuration = 0.025
let accentHz = 250.0
let accentEnvelopeDecay = 0.010
let accentBaseLevel = 0.25
let accentStrengthLevel = 0.45
let voiceGap = 0.002
let beatTightness = 100.0
// Compare before clamping: p95 clips both snare leakage and genuine kicks to 1.
// Separate them at 1.4 × p95; emitted strength still stays in 0...1.
let beatKickThreshold = 1.4
let beatTickThreshold = 0.15

let liveHistorySeconds = 62.0
let liveWindowSeconds = 60.0
let liveStartSeconds = 4.0
let liveEstimateInterval = 0.5
let liveSalienceMemory = 0.8
let liveLockedSalienceMemory = 0.95
let liveLevelInterval = 5.0
let liveLevelMargin = 1.15
let liveLevelWins = 3
let liveFitPeriodTolerance = 0.04
let liveMinimumCorrelation = 0.12
let liveMemoryWarmupSeconds = 20.0
let liveEarlyLevelInterval = 1.0
let liveLevelKickWindow = 0.035
let liveGrooveSurvivalTolerance = 0.050
let livePulseBins = 128
let livePulseSteps = 15
let livePulseStep = 0.001
let livePulseWidth = 0.015
let livePulseClip = 4.0
let livePulseContinuity = 0.2
let livePulsePhaseWidth = 0.06
let liveContinuityWidth = 0.08
let liveContinuityFloor = 0.5
let liveTempoTolerance = 0.04
let liveTempoGain = 0.3
let liveTempoWins = 3
let liveTailPeriods = 0.5
let liveFitBeats = 4
let livePhaseTolerance = 0.45
let livePhaseGain = 0.8
// Slew coherent phase changes; replace only persistent near-half-beat jumps.
let livePhaseMismatches = 3
let liveLockWins = 2
let liveTimestampGap = 0.005
let liveNoCallbackSeconds = 1.0
let liveAlignmentWindow = 4.0
let liveAlignmentRecent = 1.5
let liveAlignmentWidth = 0.040
let liveAlignmentRatio = 0.65
let liveAlignmentFloor = 0.45
let liveReacquireWindow = 7.0
let liveAlignmentClip = 4.0
let liveAlignmentDecay = 0.98
let liveAlignmentContextFloor = 0.35
let liveAlignmentMassFloor = 0.09
let liveAlignmentNewCorrelation = 0.30
let liveAlignmentOldCorrelation = 0.12
let liveAlignmentLagRadius = 2
let liveAlignmentAliasTolerance = 0.08
let liveAlignmentTupletTolerance = 0.03
let liveAlignmentPhaseBins = 64
let liveAlignmentPhaseFloor = 0.65
let liveAlignmentPhaseRatio = 0.45
let liveAlignmentPhaseWins = 2

// Intensity is independent of onset normalization and the beat clock.
let dynamicsWindowSeconds = 0.400
let dynamicsPercentile = 0.95
let dynamicsHistorySeconds = 30.0
let dynamicsFloor = 0.35
let dynamicsSmoothingSeconds = 0.300
let dynamicsStepSeconds = 0.050
let volumePollSeconds = 0.250
let minimumActuationLevel = 0.02

