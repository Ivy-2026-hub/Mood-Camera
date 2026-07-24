import Foundation
import UIKit

/// 通过阿里云百炼 OpenAI 兼容 Chat Completions 接口调用 Qwen 视觉模型。
struct QwenVisionService: AIService {
    private static let endpoint = URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")!
    private static let model = "qwen3.7-plus"
    private static let maxImagePixelSize: CGFloat = 1280
    private static let requestTimeout: TimeInterval = 30

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        configuration.timeoutIntervalForResource = Self.requestTimeout
        self.session = URLSession(configuration: configuration)
    }

    /// 读取 API Key。顺序：① 打进 App 包的 Secrets.plist（随 App 装进手机，
    /// 拔掉数据线也在）→ ② 环境变量（仅在 Xcode 运行时注入，方便调试）。
    /// 之所以两条都留，是因为环境变量只在连着 Xcode 时存在，脱机启动就没有了，
    /// 这正是“不连电脑就调不了 AI”的原因；Secrets.plist 才是随包走的正解。
    static func resolvedAPIKey() -> String? {
        if let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
           let dict = NSDictionary(contentsOf: url),
           let key = dict["DASHSCOPE_API_KEY"] as? String {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let key = ProcessInfo.processInfo.environment["DASHSCOPE_API_KEY"] {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    func generate(for entry: MoodEntry) async throws -> AIResult {
        guard let apiKey = Self.resolvedAPIKey() else {
            print("QwenVisionService: 未配置 DASHSCOPE_API_KEY（请在 Secrets.plist 或环境变量里填写）")
            throw AIServiceError.generationFailed
        }

        guard let image = PhotoFileStore().loadImage(
            fileName: entry.imageFileName,
            maxPixelSize: Self.maxImagePixelSize
        ),
        let jpegData = image.jpegData(compressionQuality: 0.8) else {
            print("QwenVisionService: 无法读取或压缩图片")
            throw AIServiceError.generationFailed
        }

        let requestBody = RequestBody(
            model: Self.model,
            messages: [
                Message(role: "system", content: .text(Self.systemPrompt)),
                Message(role: "user", content: .parts([
                    .imageURL(ImageURL(url: "data:image/jpeg;base64,\(jpegData.base64EncodedString())")),
                    .text(userPrompt(for: entry))
                ]))
            ]
        )

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestBody)

        var lastError: Error?
        for attempt in 0...1 {
            do {
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200..<300).contains(httpResponse.statusCode) else {
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                    throw QwenVisionError.httpStatus(statusCode)
                }

                let rawResponse = String(data: data, encoding: .utf8) ?? "<非 UTF-8 返回>"
                print("QwenVisionService 返回：\n\(rawResponse)")

                let completion = try JSONDecoder().decode(
                    QwenCompletionResponse.self,
                    from: data
                )
                guard let content = completion.choices.first?.message.content else {
                    throw AIServiceError.generationFailed
                }
                return try validateMoodCardResponse(content)
            } catch {
                lastError = error
                if attempt == 0 {
                    continue
                }
            }
        }

        print("QwenVisionService 请求失败：\(String(describing: lastError))")
        throw lastError ?? AIServiceError.generationFailed
    }

    private func userPrompt(for entry: MoodEntry) -> String {
        let note = entry.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let noteText = note.flatMap { $0.isEmpty ? nil : $0 } ?? "无"
        return "短笔记：\(noteText)\n拍摄时间段：\(timeSegment(for: entry.createdAt))"
    }

    private func timeSegment(for date: Date) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        switch hour {
        case 5..<9: return "早晨"
        case 9..<12: return "上午"
        case 12..<17: return "下午"
        case 17..<20: return "傍晚"
        default: return "夜里"
        }
    }

    private static let systemPrompt = """
你是 MoodPolaroid 拍立得相机里的一位朋友，观察细腻、懂一点心理学。
用户刚按下快门，你要为这一刻做一张情绪卡片。

语气：像一个爱看云、说话有点俏皮的朋友。温柔但不腻，克制但不冷。
禁止说教、禁止煽情、禁止称呼用户（不许出现"亲爱的""宝子""你呀"这类）、
禁止套用鸡汤模板句式。

只输出一个 JSON 对象，不要 Markdown 代码块，不要任何解释性文字。

{
  "emotion": "开心 / 平静 / 疲惫 / 难过 / 无聊 / 其他 之一",
  "moodCode": "情绪口令：4到10个字，给这一刻起一个可爱、有画面感的小名，
               像星巴克啡快口令那样能让人会心一笑。
               用具体的名词和感官词，不要抽象形容词堆砌。
               参考语感：加了糖的下午三点 / 靠窗的一小块太阳 /
               电量12%的星期三 / 云被风推着走",
  "summary": "10到30个字：像朋友一样说出你看到的具体细节。
              必须至少提到画面里真实存在的一样东西（颜色、物件、光线、姿态），
              让人一眼知道你真的看了这张照片。不要复述'这是一张照片'。",
  "encouragement": "8到30个字：一句贴着这张照片具体情境的鼓励。
                    不要通用鸡汤，可以俏皮，可以轻轻推一把。",
  "psychologyNote": "15到45个字：一条真实的心理学小知识，和这一刻的情绪或场景相关。
                     可以点出概念名（例如 情绪粒度、心流、曝光效应、具身认知），
                     但要用生活化的话解释。不许编造研究结论、数字或论文出处。",
  "palette": "sunny / calm / dusk / rain / neutral 之一，
              按画面的光线和气氛选，不要按情绪标签硬套"
}

硬性要求：
1. 全部中文。不要有任何emoji。
2. 不要出现"照片""图片""画面中""AI""模型"这些词，直接说内容。
3. 画面里有人时：只描述氛围、光线和状态，
   不评价外貌、身材、年龄、穿着好不好看，不猜测身份、职业、关系、健康。
4. 每次都要写出不同的句子，不要反复使用同一个开头或句式。
5. 如果画面太暗、模糊或看不清内容，emotion 用"其他"，
   仍然给出温柔的口令和鼓励，summary 就描述你确实能看到的部分。
"""
}

/// 将模型返回的情绪卡片 JSON 解析并校验为产品可写入的结果。
/// 所有字段、枚举、字数和标记符号校验集中在此函数，便于单元测试。
func validateMoodCardResponse(_ rawJSON: String) throws -> AIResult {
    let payload: MoodCardPayload
    do {
        payload = try JSONDecoder().decode(
            MoodCardPayload.self,
            from: Data(rawJSON.utf8)
        )
    } catch {
        throw MoodCardValidationError.invalidJSON
    }

    let values = [
        payload.emotion,
        payload.moodCode,
        payload.summary,
        payload.encouragement,
        payload.psychologyNote,
        payload.palette
    ].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard values.allSatisfy({ !$0.isEmpty }) else {
        throw MoodCardValidationError.missingField
    }

    guard let emotion = Emotion(displayName: values[0]) else {
        throw MoodCardValidationError.invalidEmotion
    }
    // palette 越界不该让整条生成失败——那会让卡片退回“生成失败”、连口令都拿不到，
    // 看起来就像“配色永远不变”。模型偶尔给个白名单外的词，静默退回中性色即可。
    let palette = MoodPalette.isSupported(values[5]) ? values[5] : MoodPalette.neutral.rawValue

    let textValues = Array(values.dropFirst().dropLast())
    // 长度只卡“非空且不离谱”，给模型留余地；过严的区间会把好内容也判失败。
    guard 2...16 ~= textValues[0].count,
          1...40 ~= textValues[1].count,
          4...40 ~= textValues[2].count,
          6...60 ~= textValues[3].count else {
        throw MoodCardValidationError.invalidLength
    }

    let forbiddenMarkers = CharacterSet(charactersIn: "{}[]*#<>")
    guard textValues.allSatisfy({ $0.rangeOfCharacter(from: forbiddenMarkers) == nil }) else {
        throw MoodCardValidationError.containsMarkup
    }

    return AIResult(
        emotion: emotion,
        summary: textValues[1],
        moodCode: textValues[0],
        encouragement: textValues[2],
        psychologyNote: textValues[3],
        palette: palette
    )
}

private struct QwenCompletionResponse: Decodable {
    let choices: [QwenChoice]
}

private struct QwenChoice: Decodable {
    let message: QwenMessage
}

private struct QwenMessage: Decodable {
    let content: String
}

private struct MoodCardPayload: Decodable {
    let emotion: String
    let moodCode: String
    let summary: String
    let encouragement: String
    let psychologyNote: String
    let palette: String
}

enum MoodCardValidationError: Error {
    case invalidJSON
    case missingField
    case invalidEmotion
    case invalidPalette
    case invalidLength
    case containsMarkup
}

private extension Emotion {
    init?(displayName: String) {
        switch displayName {
        case "开心": self = .happy
        case "平静": self = .calm
        case "疲惫": self = .tired
        case "难过": self = .sad
        case "无聊": self = .bored
        case "其他": self = .other
        default: return nil
        }
    }
}

private struct RequestBody: Encodable {
    let model: String
    let messages: [Message]
}

private struct Message: Encodable {
    let role: String
    let content: MessageContent
}

private enum MessageContent: Encodable {
    case text(String)
    case parts([ContentPart])

    func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .parts(let value):
            var container = encoder.unkeyedContainer()
            try value.forEach { try container.encode($0) }
        }
    }
}

private enum ContentPart: Encodable {
    case text(String)
    case imageURL(ImageURL)

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try container.encode("text", forKey: .type)
            try container.encode(value, forKey: .text)
        case .imageURL(let value):
            try container.encode("image_url", forKey: .type)
            try container.encode(value, forKey: .imageURL)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageURL = "image_url"
    }
}

private struct ImageURL: Encodable {
    let url: String
}

private enum QwenVisionError: LocalizedError {
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code): "百炼返回 HTTP 状态码 \(code)"
        }
    }
}
