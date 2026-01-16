import Foundation

/// Known Parakeet Core ML bundles that Hex supports.
public enum ParakeetModel: String, CaseIterable, Sendable {
	case englishV2 = "parakeet-tdt-0.6b-v2-coreml"
	case multilingualV3 = "parakeet-tdt-0.6b-v3-coreml"
	case nemotronStreaming = "nemotron-speech-streaming-en-0.6b-coreml"

	public static let nemotronSizeLabel = "629MB"
	public static let nemotronAccuracyStars = 4
	public static let nemotronSpeedStars = 4

	public var downloadTargetBytes: Double {
		switch self {
		case .nemotronStreaming:
			return 629 * 1024 * 1024
		default:
			return 650 * 1024 * 1024
		}
	}

	/// The identifier used throughout the app (matches the on-disk folder name).
	public var identifier: String { rawValue }

	/// Whether the model only supports English transcription.
	public var isEnglishOnly: Bool {
		switch self {
		case .englishV2, .nemotronStreaming:
			return true
		case .multilingualV3:
			return false
		}
	}

	/// Short capability label for UI copy.
	public var capabilityLabel: String {
		switch self {
		case .nemotronStreaming:
			return "English (Streaming)"
		default:
			return isEnglishOnly ? "English" : "Multilingual"
		}
	}

	/// Cache folder name used by FluidAudio downloads.
	public var cacheFolderName: String {
		switch self {
		case .nemotronStreaming:
			return "nemotron-streaming/nemotron_coreml_1120ms"
		default:
			return identifier
		}
	}

	public var remoteSubpath: String {
		switch self {
		case .nemotronStreaming:
			return "nemotron_coreml_1120ms"
		default:
			return ""
		}
	}

	/// Convenience text for recommendation badges.
	public var recommendationLabel: String {
		switch self {
		case .nemotronStreaming:
			return "Recommended (Streaming)"
		default:
			return isEnglishOnly ? "Recommended (English)" : "Recommended (Multilingual)"
		}
	}
}
