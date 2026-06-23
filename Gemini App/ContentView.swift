import SwiftUI
import Combine
import UniformTypeIdentifiers
import UIKit // Добавлено для работы с UIPasteboard

// MARK: - Провайдеры ИИ
enum AIProvider: String, Codable, CaseIterable, Identifiable {
    case gemini = "gemini"
    case openrouter = "openrouter"
    var id: String { rawValue }
}

// MARK: - Модели данных

/// Структура локального вложения (изображения или файла)
struct ChatAttachment: Identifiable, Codable, Equatable {
    var id = UUID()
    let fileName: String
    let mimeType: String
    let fileURLString: String // Путь относительно директории документов
    
    /// Ссылка на файл в локальном хранилище документов
    var localURL: URL? {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        guard let documentsDirectory = paths.first else { return nil }
        return documentsDirectory.appendingPathComponent(fileName)
    }
}

/// Структура отдельного сообщения в чате
struct ChatMessage: Identifiable, Codable, Equatable {
    var id = UUID()
    let role: MessageRole
    var content: String
    let timestamp: Date
    var attachments: [ChatAttachment]? // Массив прикрепленных файлов к сообщению
    
    enum MessageRole: String, Codable {
        case user = "user"
        case model = "model"
    }
}

/// Структура сессии чата (сохраняет историю)
struct ChatSession: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var messages: [ChatMessage]
    let createdAt: Date
}

/// Структура сохраненного системного промпта
struct SavedPrompt: Identifiable, Codable, Equatable {
    var id = UUID()
    let title: String
    let text: String
}

// MARK: - Модели для работы с Gemini API

struct GeminiRequest: Codable {
    let contents: [GeminiContent]
    let systemInstruction: GeminiSystemInstruction?
    let generationConfig: GeminiGenerationConfig?
}

struct GeminiSystemInstruction: Codable {
    let parts: [GeminiPart]
}

struct GeminiGenerationConfig: Codable {
    let temperature: Double?
}

struct GeminiContent: Codable {
    let role: String
    let parts: [GeminiPart]
}

struct GeminiPart: Codable {
    let text: String?
    let inlineData: GeminiInlineData?
}

struct GeminiInlineData: Codable {
    let mimeType: String
    let data: String // Данные в формате Base64
}

struct GeminiResponse: Codable {
    let candidates: [GeminiCandidate]?
}

struct GeminiCandidate: Codable {
    let content: GeminiContent?
    let finishReason: String?
}

// MARK: - Модели для работы с OpenRouter API (OpenAI формат)

struct ORChatRequest: Codable {
    let model: String
    let messages: [ORChatMessage]
    let temperature: Double?
    let stream: Bool
}

struct ORChatMessage: Codable {
    let role: String // "system", "user", "assistant"
    let content: ORContent
}

enum ORContent: Codable {
    case text(String)
    case parts([ORContentPart])
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let txt):
            try container.encode(txt)
        case .parts(let parts):
            try container.encode(parts)
        }
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let txt = try? container.decode(String.self) {
            self = .text(txt)
        } else if let parts = try? container.decode([ORContentPart].self) {
            self = .parts(parts)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Неверный формат контента OpenRouter")
        }
    }
}

struct ORContentPart: Codable {
    let type: String // "text" or "image_url"
    let text: String?
    let imageUrl: ORImageUrl?
    
    enum CodingKeys: String, CodingKey {
        case type, text
        case imageUrl = "image_url"
    }
}

struct ORImageUrl: Codable {
    let url: String // "data:image/jpeg;base64,..."
}

struct ORStreamResponse: Codable {
    let choices: [ORChoice]?
}

struct ORChoice: Codable {
    let delta: ORDelta?
}

struct ORDelta: Codable {
    let content: String?
}

// MARK: - Доступные модели

struct AIModelInfo: Identifiable, Hashable {
    let id: String
    let displayName: String
    let description: String
}

/// Актуальный список поддерживаемых моделей Gemini
let availableGeminiModels = [
    AIModelInfo(id: "gemini-3.5-flash", displayName: "Gemini 3.5 Flash", description: "Быстрая и умная, идеальна для повседневного общения"),
    AIModelInfo(id: "gemini-3.1-pro-preview", displayName: "Gemini 3.1 Pro", description: "Для сложных рассуждений, программирования и логики"),
    AIModelInfo(id: "gemini-3.1-flash-lite", displayName: "Gemini 3.1 Flash-Lite", description: "Максимальная скорость ответа на простые запросы"),
    AIModelInfo(id: "gemini-2.5-pro", displayName: "Gemini 2.5 Pro", description: "Глубокий анализ (предыдущее поколение)"),
    AIModelInfo(id: "gemini-2.5-flash", displayName: "Gemini 2.5 Flash", description: "Универсальный баланс (предыдущее поколение)")
]

/// Актуальный список популярных моделей OpenRouter с валидными идентификаторами
let availableOpenRouterModels = [
    AIModelInfo(id: "anthropic/claude-sonnet-4", displayName: "Claude 4 Sonnet (paid)", description: "Самая умная и быстрая модель от Anthropic"),
    AIModelInfo(id: "anthropic/claude-opus-4.7", displayName: "Claude 4.7 Opus (paid)", description: "Мощная модель для глубокого анализа и сложных задач"),
    AIModelInfo(id: "openai/gpt-5.5", displayName: "GPT-5.5 (paid)", description: "Флагманская мультимодальная модель от OpenAI"),
    AIModelInfo(id: "openai/gpt-4o-mini", displayName: "GPT-4o Mini", description: "Быстрая и экономичная модель от OpenAI"),
    AIModelInfo(id: "meta-llama/llama-3.1-70b-instruct", displayName: "Llama 3.1 70B", description: "Мощная open-source модель от Meta"),
    //AIModelInfo(id: "google/gemini-pro-1.5", displayName: "Gemini 1.5 Pro", description: "Официальный Gemini Pro через OpenRouter с огромным контекстом")
]

// MARK: - Управление состоянием (ViewModel)

class ChatViewModel: ObservableObject {
    @Published var sessions: [ChatSession] = []
    @Published var savedPrompts: [SavedPrompt] = []
    @Published var currentSessionId: UUID?
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    
    // Стейты для плавного появления текста (эффект печатной машинки)
    @Published var isTyping: Bool = false
    private var textBuffer: String = ""
    private var displayTask: Task<Void, Never>?
    
    // Статус валидации API-ключа для отображения в настройках
    @Published var keyValidationStatus: KeyStatus = .unchecked
    @Published var isCheckingKey: Bool = false
    
    enum KeyStatus: Equatable {
        case unchecked
        case valid
        case invalid(reason: String)
        case rateLimited(reason: String)
    }
    
    // Настройки провайдера
    @AppStorage("ai_provider") var provider: AIProvider = .gemini
    
    // API-ключи
    @AppStorage("gemini_api_key") var geminiApiKey: String = ""
    @AppStorage("openrouter_api_key") var openRouterApiKey: String = ""
    
    // Выбранные модели
    @AppStorage("gemini_selected_model") var geminiSelectedModel: String = "gemini-3.5-flash"
    @AppStorage("openrouter_selected_model") var openRouterSelectedModel: String = "anthropic/claude-3.5-sonnet:beta"
    
    // Общие настройки генерации
    @AppStorage("ai_temperature") var temperature: Double = 0.7
    @AppStorage("ai_system_prompt") var systemPrompt: String = ""
    
    private let userDefaultsSessionsKey = "gemini_chat_sessions"
    private let userDefaultsPromptsKey = "gemini_saved_prompts"
    
    init() {
        loadSessions()
        loadSavedPrompts()
        if sessions.isEmpty {
            createNewSession()
        } else {
            currentSessionId = sessions.first?.id
        }
    }
    
    var currentSession: ChatSession? {
        sessions.first(where: { $0.id == currentSessionId })
    }
    
    var currentModelName: String {
        if provider == .gemini {
            return availableGeminiModels.first(where: { $0.id == geminiSelectedModel })?.displayName ?? "Gemini"
        } else {
            return availableOpenRouterModels.first(where: { $0.id == openRouterSelectedModel })?.displayName ?? "OpenRouter Model"
        }
    }
    
    func loadSessions() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsSessionsKey) else { return }
        if let decoded = try? JSONDecoder().decode([ChatSession].self, from: data) {
            self.sessions = decoded
        }
    }
    
    func saveSessions() {
        if let encoded = try? JSONEncoder().encode(sessions) {
            UserDefaults.standard.set(encoded, forKey: userDefaultsSessionsKey)
        }
    }
    
    func loadSavedPrompts() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsPromptsKey) else { return }
        if let decoded = try? JSONDecoder().decode([SavedPrompt].self, from: data) {
            self.savedPrompts = decoded
        }
    }
    
    func saveNewPrompt(title: String, text: String) {
        let newPrompt = SavedPrompt(title: title, text: text)
        savedPrompts.append(newPrompt)
        if let encoded = try? JSONEncoder().encode(savedPrompts) {
            UserDefaults.standard.set(encoded, forKey: userDefaultsPromptsKey)
        }
    }
    
    func deleteSavedPrompt(at offsets: IndexSet) {
        savedPrompts.remove(atOffsets: offsets)
        if let encoded = try? JSONEncoder().encode(savedPrompts) {
            UserDefaults.standard.set(encoded, forKey: userDefaultsPromptsKey)
        }
    }
    
    func createNewSession() {
        let newSession = ChatSession(title: "Новый чат \(sessions.count + 1)", messages: [], createdAt: Date())
        sessions.insert(newSession, at: 0)
        currentSessionId = newSession.id
        saveSessions()
    }
    
    func selectSession(_ id: UUID) {
        currentSessionId = id
    }
    
    func deleteSession(at offsets: IndexSet) {
        sessions.remove(atOffsets: offsets)
        if let first = sessions.first {
            currentSessionId = first.id
        } else {
            createNewSession()
        }
        saveSessions()
    }
    
    func saveFileToDisk(data: Data, fileName: String) -> String? {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        guard let documentsDirectory = paths.first else { return nil }
        
        let uniqueName = "\(UUID().uuidString)_\(fileName)"
        let fileURL = documentsDirectory.appendingPathComponent(uniqueName)
        do {
            try data.write(to: fileURL)
            return uniqueName
        } catch {
            print("Ошибка при записи файла на диск: \(error)")
            return nil
        }
    }
    
    /// Универсальная проверка ключа
    func validateApiKey(_ keyToCheck: String, for checkProvider: AIProvider) async {
        let trimmedKey = keyToCheck.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            await MainActor.run { self.keyValidationStatus = .invalid(reason: "Ключ не может быть пустым.") }
            return
        }
        
        await MainActor.run {
            self.isCheckingKey = true
            self.keyValidationStatus = .unchecked
        }
        
        var request: URLRequest
        
        if checkProvider == .gemini {
            let urlString = "https://generativelanguage.googleapis.com/v1beta/models?key=\(trimmedKey)"
            guard let url = URL(string: urlString) else {
                await MainActor.run { self.isCheckingKey = false; self.keyValidationStatus = .invalid(reason: "Некорректный формат URL.") }
                return
            }
            request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            
        } else {
            // OpenRouter Validation (auth check)
            let urlString = "https://openrouter.ai/api/v1/auth/key"
            guard let url = URL(string: urlString) else {
                await MainActor.run { self.isCheckingKey = false; self.keyValidationStatus = .invalid(reason: "Некорректный формат URL.") }
                return
            }
            request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.addValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        }
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            
            if httpResponse.statusCode == 200 {
                await MainActor.run { self.isCheckingKey = false; self.keyValidationStatus = .valid }
            } else {
                var parsedErrorMessage = "Код ошибки: \(httpResponse.statusCode)"
                if let errorJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errorDetails = errorJSON["error"] as? [String: Any] {
                    if let message = errorDetails["message"] as? String { parsedErrorMessage = message }
                }
                
                await MainActor.run {
                    self.isCheckingKey = false
                    if httpResponse.statusCode == 429 {
                        self.keyValidationStatus = .rateLimited(reason: "Лимит запросов исчерпан. Подробнее: \(parsedErrorMessage)")
                    } else {
                        self.keyValidationStatus = .invalid(reason: "Ошибка проверки ключа! \(parsedErrorMessage)")
                    }
                }
            }
        } catch {
            await MainActor.run {
                self.isCheckingKey = false
                self.keyValidationStatus = .invalid(reason: "Ошибка соединения: \(error.localizedDescription)")
            }
        }
    }
    
    /// Отправка сообщения
    func sendMessage(text: String, attachments: [ChatAttachment]) async {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty || !attachments.isEmpty else { return }
        
        let activeKey = provider == .gemini ? geminiApiKey : openRouterApiKey
        guard !activeKey.isEmpty else {
            await MainActor.run { self.errorMessage = "Пожалуйста, укажите API-ключ \(provider == .gemini ? "Gemini" : "OpenRouter") в настройках." }
            return
        }
        
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == currentSessionId }) else { return }
        
        let userMessage = ChatMessage(role: .user, content: trimmedText, timestamp: Date(), attachments: attachments)
        let modelMessageId = UUID()
        
        await MainActor.run {
            self.sessions[sessionIndex].messages.append(userMessage)
            if self.sessions[sessionIndex].title.hasPrefix("Новый чат") {
                let preview = trimmedText.isEmpty ? "Файл/Изображение" : String(trimmedText.prefix(25))
                self.sessions[sessionIndex].title = preview + (trimmedText.count > 25 ? "..." : "")
            }
            let placeholderMessage = ChatMessage(id: modelMessageId, role: .model, content: "", timestamp: Date(), attachments: nil)
            self.sessions[sessionIndex].messages.append(placeholderMessage)
            
            self.isLoading = true
            self.errorMessage = nil
            self.saveSessions()
        }
        
        if provider == .gemini {
            let apiMessages = prepareGeminiMessages(for: sessionIndex, adding: nil)
            await executeGeminiApiCall(apiMessages: apiMessages, sessionIndex: sessionIndex, targetMessageId: modelMessageId)
        } else {
            let apiMessages = prepareOpenRouterMessages(for: sessionIndex, adding: nil)
            await executeOpenRouterApiCall(apiMessages: apiMessages, sessionIndex: sessionIndex, targetMessageId: modelMessageId)
        }
    }
    
    /// Повторная отправка
    func retryLastMessage() async {
        let activeKey = provider == .gemini ? geminiApiKey : openRouterApiKey
        guard !activeKey.isEmpty else {
            await MainActor.run { self.errorMessage = "Пожалуйста, укажите API-ключ в настройках." }
            return
        }
        
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == currentSessionId }) else { return }
        
        if let lastMsg = sessions[sessionIndex].messages.last, lastMsg.role == .model {
            await MainActor.run { self.sessions[sessionIndex].messages.removeLast() }
        }
        guard sessions[sessionIndex].messages.last?.role == .user else { return }
        
        let modelMessageId = UUID()
        
        await MainActor.run {
            self.isLoading = true
            self.errorMessage = nil
            let placeholderMessage = ChatMessage(id: modelMessageId, role: .model, content: "", timestamp: Date(), attachments: nil)
            self.sessions[sessionIndex].messages.append(placeholderMessage)
        }
        
        if provider == .gemini {
            let apiMessages = prepareGeminiMessages(for: sessionIndex, adding: nil)
            await executeGeminiApiCall(apiMessages: apiMessages, sessionIndex: sessionIndex, targetMessageId: modelMessageId)
        } else {
            let apiMessages = prepareOpenRouterMessages(for: sessionIndex, adding: nil)
            await executeOpenRouterApiCall(apiMessages: apiMessages, sessionIndex: sessionIndex, targetMessageId: modelMessageId)
        }
    }
    
    // MARK: - Подготовка сообщений
    
    private func prepareGeminiMessages(for sessionIndex: Int, adding newMessage: ChatMessage?) -> [GeminiContent] {
        var allMessages = sessions[sessionIndex].messages
        if let newMsg = newMessage { allMessages.append(newMsg) }
        
        return allMessages.map { msg -> GeminiContent in
            let apiRole = msg.role == .user ? "user" : "model"
            var parts: [GeminiPart] = []
            if !msg.content.isEmpty { parts.append(GeminiPart(text: msg.content, inlineData: nil)) }
            if let attachments = msg.attachments {
                for attachment in attachments {
                    if let url = attachment.localURL, let fileData = try? Data(contentsOf: url) {
                        let base64 = fileData.base64EncodedString()
                        let inline = GeminiInlineData(mimeType: attachment.mimeType, data: base64)
                        parts.append(GeminiPart(text: nil, inlineData: inline))
                    }
                }
            }
            if parts.isEmpty { parts.append(GeminiPart(text: " ", inlineData: nil)) }
            return GeminiContent(role: apiRole, parts: parts)
        }
    }
    
    private func prepareOpenRouterMessages(for sessionIndex: Int, adding newMessage: ChatMessage?) -> [ORChatMessage] {
        var allMessages = sessions[sessionIndex].messages
        if let newMsg = newMessage { allMessages.append(newMsg) }
        
        var apiMessages: [ORChatMessage] = []
        if !systemPrompt.isEmpty {
            apiMessages.append(ORChatMessage(role: "system", content: .text(systemPrompt)))
        }
        
        for msg in allMessages {
            let role = msg.role == .user ? "user" : "assistant"
            
            if msg.role == .user {
                if let attachments = msg.attachments, !attachments.isEmpty {
                    var parts: [ORContentPart] = []
                    if !msg.content.isEmpty {
                        parts.append(ORContentPart(type: "text", text: msg.content, imageUrl: nil))
                    }
                    
                    for attachment in attachments {
                        if let url = attachment.localURL, let fileData = try? Data(contentsOf: url) {
                            if attachment.mimeType.hasPrefix("image/") {
                                let base64String = fileData.base64EncodedString()
                                let dataUri = "data:\(attachment.mimeType);base64,\(base64String)"
                                parts.append(ORContentPart(type: "image_url", text: nil, imageUrl: ORImageUrl(url: dataUri)))
                            } else {
                                parts.append(ORContentPart(type: "text", text: "\n[Файл: \(attachment.fileName) прикреплен, но OpenRouter поддерживает только изображения]", imageUrl: nil))
                            }
                        }
                    }
                    if parts.isEmpty { parts.append(ORContentPart(type: "text", text: " ", imageUrl: nil)) }
                    apiMessages.append(ORChatMessage(role: role, content: .parts(parts)))
                } else {
                    apiMessages.append(ORChatMessage(role: role, content: .text(msg.content.isEmpty ? " " : msg.content)))
                }
            } else {
                apiMessages.append(ORChatMessage(role: role, content: .text(msg.content)))
            }
        }
        return apiMessages
    }
    
    // MARK: - Сетевые вызовы
    
    private func executeGeminiApiCall(apiMessages: [GeminiContent], sessionIndex: Int, targetMessageId: UUID) async {
        let sysInstruct = systemPrompt.isEmpty ? nil : GeminiSystemInstruction(parts: [GeminiPart(text: systemPrompt, inlineData: nil)])
        let genConfig = GeminiGenerationConfig(temperature: temperature)
        let requestBody = GeminiRequest(contents: apiMessages, systemInstruction: sysInstruct, generationConfig: genConfig)
        
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(geminiSelectedModel):streamGenerateContent?alt=sse&key=\(geminiApiKey)"
        guard let url = URL(string: urlString) else {
            await handleError(sessionIndex: sessionIndex, targetMessageId: targetMessageId, errorMsg: "Некорректный URL API")
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        await MainActor.run { self.textBuffer = ""; self.startSmoothTyping(sessionIndex: sessionIndex, messageId: targetMessageId) }
        
        do {
            request.httpBody = try JSONEncoder().encode(requestBody)
            let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            
            if httpResponse.statusCode != 200 { throw try await parseErrorBytes(asyncBytes, code: httpResponse.statusCode) }
            
            var hasReceivedContent = false
            for try await line in asyncBytes.lines {
                guard line.hasPrefix("data: ") else { continue }
                let jsonString = String(line.dropFirst(6))
                if jsonString == "[DONE]" { break }
                
                if let data = jsonString.data(using: .utf8),
                   let decoded = try? JSONDecoder().decode(GeminiResponse.self, from: data),
                   let textPiece = decoded.candidates?.first?.content?.parts.first?.text {
                    hasReceivedContent = true
                    await MainActor.run { self.textBuffer += textPiece }
                }
            }
            if !hasReceivedContent { throw NSError(domain: "AppError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Пустой ответ"]) }
            await MainActor.run { self.isLoading = false }
        } catch {
            await handleError(sessionIndex: sessionIndex, targetMessageId: targetMessageId, errorMsg: error.localizedDescription)
        }
    }
    
    private func executeOpenRouterApiCall(apiMessages: [ORChatMessage], sessionIndex: Int, targetMessageId: UUID) async {
        let requestBody = ORChatRequest(model: openRouterSelectedModel, messages: apiMessages, temperature: temperature, stream: true)
        
        let urlString = "https://openrouter.ai/api/v1/chat/completions"
        guard let url = URL(string: urlString) else {
            await handleError(sessionIndex: sessionIndex, targetMessageId: targetMessageId, errorMsg: "Некорректный URL API")
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(openRouterApiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("https://github.com/swiftui-chat", forHTTPHeaderField: "HTTP-Referer")
        request.addValue("SwiftUI Chat", forHTTPHeaderField: "X-Title")
        
        await MainActor.run { self.textBuffer = ""; self.startSmoothTyping(sessionIndex: sessionIndex, messageId: targetMessageId) }
        
        do {
            request.httpBody = try JSONEncoder().encode(requestBody)
            let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            
            if httpResponse.statusCode != 200 { throw try await parseErrorBytes(asyncBytes, code: httpResponse.statusCode) }
            
            var hasReceivedContent = false
            for try await line in asyncBytes.lines {
                guard line.hasPrefix("data: ") else { continue }
                let jsonString = String(line.dropFirst(6))
                if jsonString == "[DONE]" { break }
                
                if let data = jsonString.data(using: .utf8),
                   let decoded = try? JSONDecoder().decode(ORStreamResponse.self, from: data),
                   let textPiece = decoded.choices?.first?.delta?.content {
                    hasReceivedContent = true
                    await MainActor.run { self.textBuffer += textPiece }
                }
            }
            if !hasReceivedContent { throw NSError(domain: "AppError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Пустой ответ"]) }
            await MainActor.run { self.isLoading = false }
        } catch {
            await handleError(sessionIndex: sessionIndex, targetMessageId: targetMessageId, errorMsg: error.localizedDescription)
        }
    }
    
    // Вспомогательные методы
    private func parseErrorBytes<T: AsyncSequence>(_ asyncBytes: T, code: Int) async throws -> NSError where T.Element == UInt8 {
        var errorData = Data()
        for try await byte in asyncBytes { errorData.append(byte) }
        var detailedError = "Ошибка сервера (Код \(code))"
        if let errorJSON = try? JSONSerialization.jsonObject(with: errorData) as? [String: Any],
           let errorDetails = errorJSON["error"] as? [String: Any],
           let message = errorDetails["message"] as? String {
            detailedError = message
        }
        return NSError(domain: "APIError", code: code, userInfo: [NSLocalizedDescriptionKey: detailedError])
    }
    
    private func handleError(sessionIndex: Int, targetMessageId: UUID, errorMsg: String) async {
        await MainActor.run {
            self.isLoading = false
            self.errorMessage = errorMsg
            if let msgIndex = self.sessions[sessionIndex].messages.firstIndex(where: { $0.id == targetMessageId }),
               self.sessions[sessionIndex].messages[msgIndex].content.isEmpty {
                self.sessions[sessionIndex].messages.remove(at: msgIndex)
            }
        }
    }
    
    private func startSmoothTyping(sessionIndex: Int, messageId: UUID) {
        displayTask?.cancel()
        displayTask = Task { @MainActor in
            self.isTyping = true
            while !Task.isCancelled {
                if !self.textBuffer.isEmpty {
                    let takeCount = max(2, self.textBuffer.count / 8)
                    let chunk = String(self.textBuffer.prefix(takeCount))
                    self.textBuffer.removeFirst(chunk.count)
                    if let msgIndex = self.sessions[sessionIndex].messages.firstIndex(where: { $0.id == messageId }) {
                        self.sessions[sessionIndex].messages[msgIndex].content += chunk
                    }
                } else if !self.isLoading { break }
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
            self.isTyping = false
            self.saveSessions()
        }
    }
}


// MARK: - Парсинг и Рендеринг Markdown (iOS 15+)

enum MarkdownBlock: Identifiable, Equatable {
    var id: UUID { UUID() }
    case text(AttributedString)
    case header(text: AttributedString, level: Int)
    case quote(AttributedString)
    case codeBlock(code: String, language: String)
    case divider
}

struct MarkdownParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = text.components(separatedBy: .newlines)
        var currentTextLines: [String] = []
        var currentQuoteLines: [String] = []
        var isInsideCodeBlock = false
        var codeLanguage = ""
        
        func flushText() {
            let joined = currentTextLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.text(parseInline(joined))) }
            currentTextLines.removeAll()
        }
        
        func flushQuote() {
            let joined = currentQuoteLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.quote(parseInline(joined))) }
            currentQuoteLines.removeAll()
        }
        
        for line in lines {
            if line.hasPrefix("```") {
                if isInsideCodeBlock {
                    blocks.append(.codeBlock(code: currentTextLines.joined(separator: "\n"), language: codeLanguage))
                    currentTextLines.removeAll()
                    isInsideCodeBlock = false
                } else {
                    flushText(); flushQuote()
                    isInsideCodeBlock = true
                    codeLanguage = String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                continue
            }
            if isInsideCodeBlock { currentTextLines.append(line); continue }
            
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine == "---" || trimmedLine == "***" || trimmedLine == "___" {
                flushText(); flushQuote(); blocks.append(.divider); continue
            }
            
            if line.hasPrefix("# ") { flushText(); flushQuote(); blocks.append(.header(text: parseInline(String(line.dropFirst(2))), level: 1)); continue }
            else if line.hasPrefix("## ") { flushText(); flushQuote(); blocks.append(.header(text: parseInline(String(line.dropFirst(3))), level: 2)); continue }
            else if line.hasPrefix("### ") { flushText(); flushQuote(); blocks.append(.header(text: parseInline(String(line.dropFirst(4))), level: 3)); continue }
            
            if line.hasPrefix(">") {
                flushText()
                currentQuoteLines.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            } else { flushQuote() }
            
            currentTextLines.append(line)
        }
        flushText(); flushQuote()
        return blocks
    }
    
    private static func parseInline(_ text: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        if let attrString = try? AttributedString(markdown: text, options: options) { return attrString }
        return AttributedString(text)
    }
}

// MARK: - SwiftUI Компоненты Markdown

struct MarkdownView: View {
    let text: String
    let textColor: Color
    var body: some View {
        let blocks = MarkdownParser.parse(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<blocks.count, id: \.self) { index in
                switch blocks[index] {
                case .text(let attrString):
                    Text(attrString).font(.body).foregroundColor(textColor).tint(textColor == .white ? .white : .blue).textSelection(.enabled)
                case .header(let attrString, let level):
                    Text(attrString).font(.system(size: level == 1 ? 22 : (level == 2 ? 19 : 17), weight: .bold)).foregroundColor(textColor).tint(textColor == .white ? .white : .blue).textSelection(.enabled).padding(.top, 6).padding(.bottom, 2)
                case .quote(let attrString):
                    HStack(spacing: 12) {
                        Rectangle().fill(textColor.opacity(0.3)).frame(width: 3)
                        Text(attrString).font(.body).foregroundColor(textColor.opacity(0.8)).tint(textColor == .white ? .white : .blue).textSelection(.enabled)
                    }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 4)
                case .codeBlock(let code, let language):
                    CodeBlockView(code: code, language: language).padding(.vertical, 4)
                case .divider:
                    Divider().background(textColor.opacity(0.3)).padding(.vertical, 8)
                }
            }
        }
    }
}

struct CodeBlockView: View {
    let code: String
    let language: String
    @State private var isCopied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "CODE" : language.uppercased()).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundColor(.secondary)
                Spacer()
                Button(action: {
                    UIPasteboard.general.string = code
                    withAnimation { isCopied = true }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { isCopied = false } }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        Text(isCopied ? "Скопировано" : "Копировать")
                    }.font(.system(size: 11, weight: .semibold)).foregroundColor(isCopied ? .green : .blue)
                }.buttonStyle(.borderless)
            }.padding(.horizontal, 12).padding(.vertical, 8).background(Color(.systemGray5))
            
            ScrollView(.horizontal, showsIndicators: true) {
                Text(code).font(.system(size: 13, weight: .regular, design: .monospaced)).foregroundColor(Color(.label)).padding(12).textSelection(.enabled)
            }.background(Color(.systemGray6))
        }.cornerRadius(10).overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(.systemGray4), lineWidth: 1))
    }
}

// MARK: - Основной экран приложения (Интерфейс)

struct ContentView: View {
    @StateObject private var viewModel = ChatViewModel()
    @State private var showingSettings = false
    @State private var showingHistory = false
    @State private var inputText = ""
    
    var body: some View {
        NavigationView {
            ChatRoomView(viewModel: viewModel, inputText: $inputText)
                .navigationTitle(viewModel.currentSession?.title ?? "Чат с ИИ")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(action: { showingHistory = true }) {
                            HStack(spacing: 5) {
                                Image(systemName: "list.bullet")
                                Text("История").font(.subheadline)
                            }
                        }
                    }
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 2) {
                            Text(viewModel.currentSession?.title ?? "Новый чат").font(.headline)
                            Text(viewModel.currentModelName).font(.system(size: 10, weight: .bold)).foregroundColor(viewModel.provider == .gemini ? .blue : .purple)
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        HStack(spacing: 16) {
                            Button(action: { viewModel.createNewSession() }) { Image(systemName: "square.and.pencil") }
                            Button(action: { showingSettings = true }) { Image(systemName: "gearshape.fill") }
                        }
                    }
                }
        }
        .navigationViewStyle(.stack)
        .sheet(isPresented: $showingHistory) { HistoryView(viewModel: viewModel, isPresented: $showingHistory) }
        .sheet(isPresented: $showingSettings) { SettingsView(viewModel: viewModel, isPresented: $showingSettings) }
    }
}

// MARK: - UIImagePickerController Wrapper

struct ImagePicker: UIViewControllerRepresentable {
    let onPick: (UIImage, Data, String) -> Void
    @Environment(\.presentationMode) private var presentationMode
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController(); picker.delegate = context.coordinator; return picker
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    
    class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: ImagePicker
        init(_ parent: ImagePicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let image = info[.originalImage] as? UIImage {
                let resized = resizeImage(image: image, targetSize: CGSize(width: 1200, height: 1200))
                if let jpegData = resized.jpegData(compressionQuality: 0.8) {
                    let fileName = "photo_\(Int(Date().timeIntervalSince1970)).jpg"
                    parent.onPick(image, jpegData, fileName)
                }
            }
            parent.presentationMode.wrappedValue.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.presentationMode.wrappedValue.dismiss() }
        private func resizeImage(image: UIImage, targetSize: CGSize) -> UIImage {
            let size = image.size
            let widthRatio  = targetSize.width  / size.width; let heightRatio = targetSize.height / size.height
            let newSize = widthRatio > heightRatio ? CGSize(width: size.width * heightRatio, height: size.height * heightRatio) : CGSize(width: size.width * widthRatio,  height: size.height * widthRatio)
            let rect = CGRect(origin: .zero, size: newSize)
            UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0); image.draw(in: rect)
            let newImage = UIGraphicsGetImageFromCurrentImageContext(); UIGraphicsEndImageContext()
            return newImage ?? image
        }
    }
}

// MARK: - UIDocumentPickerViewController Wrapper

struct DocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL, Data, String) -> Void
    @Environment(\.presentationMode) private var presentationMode
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data, .content])
        picker.delegate = context.coordinator; return picker
    }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPicker
        init(_ parent: DocumentPicker) { self.parent = parent }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            let shouldStopAccessing = url.startAccessingSecurityScopedResource()
            defer { if shouldStopAccessing { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) { parent.onPick(url, data, url.lastPathComponent) }
            parent.presentationMode.wrappedValue.dismiss()
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { parent.presentationMode.wrappedValue.dismiss() }
    }
}

// MARK: - Экран истории чатов

struct HistoryView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Binding var isPresented: Bool
    
    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Сохраненные диалоги")) {
                    if viewModel.sessions.isEmpty {
                        Text("История пуста").foregroundColor(.secondary)
                    } else {
                        ForEach(viewModel.sessions) { session in
                            Button(action: { viewModel.selectSession(session.id); isPresented = false }) {
                                HStack(spacing: 12) {
                                    Image(systemName: "bubble.left.and.bubble.right.fill").foregroundColor(.blue).font(.body)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(session.title).font(.system(size: 17, weight: .semibold)).foregroundColor(.primary).lineLimit(1)
                                        if let lastMsg = session.messages.last {
                                            Text(lastMsg.content.isEmpty ? "Файл / Изображение" : lastMsg.content).font(.caption).foregroundColor(.secondary).lineLimit(1)
                                        } else { Text("Пустой чат").font(.caption).foregroundColor(.secondary) }
                                    }
                                    Spacer()
                                    if session.id == viewModel.currentSessionId { Image(systemName: "checkmark.circle.fill").foregroundColor(.green) }
                                }
                                .padding(.vertical, 4)
                            }
                        }.onDelete(perform: viewModel.deleteSession)
                    }
                }
            }
            .listStyle(InsetGroupedListStyle())
            .navigationTitle("История чатов")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Закрыть") { isPresented = false } } }
        }
    }
}

// MARK: - Экран настроек (SettingsView)

struct SettingsView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Binding var isPresented: Bool
    
    @State private var tempProvider: AIProvider = .gemini
    @State private var tempGeminiKey: String = ""
    @State private var tempOpenRouterKey: String = ""
    @State private var tempGeminiModel: String = "gemini-3.5-flash"
    @State private var tempOpenRouterModel: String = "anthropic/claude-3.5-sonnet:beta"
    @State private var tempTemperature: Double = 0.7
    @State private var tempSystemPrompt: String = ""
    
    @State private var showingSavePromptAlert = false
    @State private var newPromptTitle = ""
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("ПРОВАЙДЕР ИИ")) {
                    Picker("Сервис", selection: $tempProvider) {
                        Text("Gemini API").tag(AIProvider.gemini)
                        Text("OpenRouter").tag(AIProvider.openrouter)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .onChange(of: tempProvider) { _ in
                        viewModel.keyValidationStatus = .unchecked
                    }
                }
                
                Section(header: Text("API-КЛЮЧ \(tempProvider == .gemini ? "GEMINI" : "OPENROUTER")"), footer: Text(tempProvider == .gemini ? "Бесплатный ключ на aistudio.google.com имеет лимиты." : "Ключ OpenRouter доступен на сайте openrouter.ai/keys")) {
                    HStack(spacing: 12) {
                        if tempProvider == .gemini {
                            SecureField("API-ключ Gemini", text: $tempGeminiKey)
                                .onChange(of: tempGeminiKey) { _ in viewModel.keyValidationStatus = .unchecked }
                        } else {
                            SecureField("API-ключ OpenRouter", text: $tempOpenRouterKey)
                                .onChange(of: tempOpenRouterKey) { _ in viewModel.keyValidationStatus = .unchecked }
                        }
                        
                        if viewModel.isCheckingKey {
                            ProgressView().frame(width: 24, height: 24)
                        } else {
                            Button(action: {
                                Task { await viewModel.validateApiKey(tempProvider == .gemini ? tempGeminiKey : tempOpenRouterKey, for: tempProvider) }
                            }) {
                                Image(systemName: "arrow.clockwise.circle.fill").font(.system(size: 22)).foregroundColor(.blue)
                            }.buttonStyle(.borderless)
                        }
                    }
                    
                    switch viewModel.keyValidationStatus {
                    case .unchecked: EmptyView()
                    case .valid: HStack { Image(systemName: "checkmark.shield.fill").foregroundColor(.green); Text("Ключ активен!").font(.footnote).foregroundColor(.green) }.padding(.top, 2)
                    case .invalid(let reason): HStack(alignment: .top) { Image(systemName: "exclamationmark.shield.fill").foregroundColor(.red); Text(reason).font(.footnote).foregroundColor(.red) }.padding(.top, 2)
                    case .rateLimited(let reason): HStack(alignment: .top) { Image(systemName: "clock.badge.exclamationmark.fill").foregroundColor(.orange); Text(reason).font(.footnote).foregroundColor(.orange) }.padding(.top, 2)
                    }
                    
                    Link(destination: URL(string: tempProvider == .gemini ? "[https://aistudio.google.com/](https://aistudio.google.com/)" : "[https://openrouter.ai/keys](https://openrouter.ai/keys)")!) {
                        HStack { Text("Получить API ключ").font(.footnote); Spacer(); Image(systemName: "arrow.up.right").font(.caption) }
                    }
                }
                
                Section(header: Text("ВЫБОР МОДЕЛИ")) {
                    if tempProvider == .gemini {
                        ForEach(availableGeminiModels, id: \.id) { model in
                            ModelRow(model: model, isSelected: tempGeminiModel == model.id) { tempGeminiModel = model.id }
                        }
                    } else {
                        ForEach(availableOpenRouterModels, id: \.id) { model in
                            ModelRow(model: model, isSelected: tempOpenRouterModel == model.id) { tempOpenRouterModel = model.id }
                        }
                    }
                }
                
                Section(header: Text("НАСТРОЙКИ ГЕНЕРАЦИИ")) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { Text("Температура ответа:"); Spacer(); Text(String(format: "%.1f", tempTemperature)).fontWeight(.bold) }
                        Slider(value: $tempTemperature, in: 0.0...2.0, step: 0.1)
                        Text("Меньше — более точные ответы, больше — более креативные.").font(.caption).foregroundColor(.secondary)
                    }.padding(.vertical, 4)
                }
                
                Section(header: Text("СИСТЕМНЫЙ ПРОМПТ")) {
                    VStack(alignment: .leading, spacing: 4) {
                        TextEditor(text: $tempSystemPrompt).frame(minHeight: 80).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(.systemGray4), lineWidth: 1))
                        Text("Инструкции, определяющие поведение нейросети (роль, стиль).").font(.caption).foregroundColor(.secondary)
                    }.padding(.vertical, 4)
                    
                    Button(action: { newPromptTitle = ""; showingSavePromptAlert = true }) {
                        HStack { Image(systemName: "square.and.arrow.down"); Text("Сохранить текущий промпт") }
                    }.disabled(tempSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                
                Section(header: Text("СОХРАНЕННЫЕ ПРОМПТЫ")) {
                    if viewModel.savedPrompts.isEmpty {
                        Text("Нет сохраненных промптов").foregroundColor(.secondary)
                    } else {
                        ForEach(viewModel.savedPrompts) { prompt in
                            Button(action: { tempSystemPrompt = prompt.text }) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(prompt.title).foregroundColor(.primary).font(.system(size: 16, weight: .medium))
                                        Text(prompt.text).font(.caption).foregroundColor(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.up.doc").foregroundColor(.blue).font(.system(size: 14))
                                }
                            }
                        }.onDelete(perform: viewModel.deleteSavedPrompt)
                    }
                }
                
                Section(footer: Text("Настройки сохраняются только локально на вашем устройстве.")) {
                    Button(action: saveSettings) {
                        Text("Сохранить настройки").frame(maxWidth: .infinity).foregroundColor(.white).font(.system(size: 17, weight: .semibold)).padding(.vertical, 8)
                    }.buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button("Отмена") { isPresented = false } } }
            .onAppear {
                tempProvider = viewModel.provider
                tempGeminiKey = viewModel.geminiApiKey
                tempOpenRouterKey = viewModel.openRouterApiKey
                tempGeminiModel = viewModel.geminiSelectedModel
                tempOpenRouterModel = viewModel.openRouterSelectedModel
                tempTemperature = viewModel.temperature
                tempSystemPrompt = viewModel.systemPrompt
            }
            .alert("Сохранить промпт", isPresented: $showingSavePromptAlert) {
                TextField("Название промпта", text: $newPromptTitle)
                Button("Отмена", role: .cancel) { }
                Button("Сохранить") {
                    let title = newPromptTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Без названия" : newPromptTitle
                    viewModel.saveNewPrompt(title: title, text: tempSystemPrompt)
                }
            } message: { Text("Введите название для сохранения текущего промпта.") }
        }
    }
    
    private func saveSettings() {
        viewModel.provider = tempProvider
        viewModel.geminiApiKey = tempGeminiKey
        viewModel.openRouterApiKey = tempOpenRouterKey
        viewModel.geminiSelectedModel = tempGeminiModel
        viewModel.openRouterSelectedModel = tempOpenRouterModel
        viewModel.temperature = tempTemperature
        viewModel.systemPrompt = tempSystemPrompt
        isPresented = false
    }
}

struct ModelRow: View {
    let model: AIModelInfo
    let isSelected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.displayName).foregroundColor(.primary).font(.system(size: 17, weight: isSelected ? .semibold : .regular))
                    Text(model.description).font(.caption).foregroundColor(.secondary).multilineTextAlignment(.leading)
                }
                Spacer()
                if isSelected { Image(systemName: "checkmark").foregroundColor(.blue).font(.system(size: 14, weight: .bold)) }
            }.padding(.vertical, 4)
        }
    }
}

// MARK: - Окно самого диалога (Чат)

struct PendingAttachment: Identifiable {
    let id = UUID()
    let fileName: String
    let mimeType: String
    let data: Data
    let image: UIImage?
}

struct ChatRoomView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Binding var inputText: String
    
    @State private var showImagePicker = false
    @State private var showDocumentPicker = false
    @State private var pendingAttachments: [PendingAttachment] = []
    
    var body: some View {
        VStack(spacing: 0) {
            if let session = viewModel.currentSession {
                if session.messages.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: viewModel.provider == .gemini ? "sparkles" : "network")
                            .font(.system(size: 70))
                            .foregroundColor((viewModel.provider == .gemini ? Color.blue : Color.purple).opacity(0.85))
                        Text(viewModel.provider == .gemini ? "Привет! Я Gemini" : "Привет! Я ИИ-ассистент").font(.title).bold()
                        Text("Спросите меня о чем-нибудь. Вы можете прикреплять фотографии и файлы с помощью кнопки «+» внизу.").font(.body).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal, 40)
                    }.frame(maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 16) {
                                ForEach(session.messages) { message in MessageBubble(message: message).id(message.id) }
                                
                                if viewModel.isLoading && (session.messages.last?.role == .user || session.messages.last?.content.isEmpty == true) {
                                    HStack {
                                        ProgressView().padding(.trailing, 8); Text("ИИ думает...").font(.footnote).foregroundColor(.secondary); Spacer()
                                    }.padding().background(Color(.systemGray6)).cornerRadius(14).padding(.horizontal).id("loadingIndicator")
                                }
                                
                                if let error = viewModel.errorMessage {
                                    VStack(alignment: .leading, spacing: 12) {
                                        HStack {
                                            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                                            Text("Ошибка отправки").font(.system(size: 16, weight: .semibold)).foregroundColor(.red)
                                            Spacer()
                                            Button(action: { Task { await viewModel.retryLastMessage() } }) {
                                                HStack(spacing: 4) { Image(systemName: "arrow.clockwise"); Text("Повторить") }.font(.system(size: 13, weight: .bold)).foregroundColor(.white).padding(.horizontal, 10).padding(.vertical, 6).background(Color.red).cornerRadius(8)
                                            }
                                        }
                                        Text(error).font(.footnote).foregroundColor(.secondary)
                                    }.padding().background(Color.red.opacity(0.08)).cornerRadius(14).padding(.horizontal).id("errorIndicator")
                                }
                            }.padding(.vertical)
                        }
                        .background(Color.clear.contentShape(Rectangle()).onTapGesture { hideKeyboard() })
                        .simultaneousGesture(DragGesture().onChanged { value in if value.translation.height > 15 { hideKeyboard() } })
                        .onChange(of: session.messages) { _ in scrollToBottom(proxy: proxy, session: session) }
                        .onChange(of: viewModel.isLoading) { _ in scrollToBottom(proxy: proxy, session: session) }
                        .onAppear { scrollToBottom(proxy: proxy, session: session) }
                    }
                }
            } else {
                Text("Пожалуйста, создайте новый чат").foregroundColor(.secondary).frame(maxHeight: .infinity)
            }
            
            Divider()
            
            if !pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(pendingAttachments) { item in
                            ZStack(alignment: .topTrailing) {
                                HStack(spacing: 8) {
                                    if let img = item.image {
                                        Image(uiImage: img).resizable().scaledToFill().frame(width: 44, height: 44).cornerRadius(8).clipped()
                                    } else {
                                        ZStack { Color.blue.opacity(0.1); Image(systemName: "doc.fill").foregroundColor(.blue).font(.system(size: 16)) }.frame(width: 44, height: 44).cornerRadius(8)
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.fileName).font(.system(size: 12, weight: .semibold)).foregroundColor(.primary).lineLimit(1).frame(maxWidth: 100)
                                        Text(item.mimeType.components(separatedBy: "/").last?.uppercased() ?? "FILE").font(.system(size: 8)).foregroundColor(.secondary)
                                    }
                                }.padding(.vertical, 6).padding(.horizontal, 10).background(Color(.systemGray6)).cornerRadius(12)
                                Button(action: { pendingAttachments.removeAll(where: { $0.id == item.id }) }) {
                                    Image(systemName: "xmark.circle.fill").foregroundColor(.gray).background(Color.white.clipShape(Circle())).font(.system(size: 16)).offset(x: 4, y: -4)
                                }
                            }
                        }
                    }.padding(.horizontal).padding(.top, 8)
                }
            }
            
            HStack(spacing: 12) {
                Menu {
                    Button(action: { showImagePicker = true }) { Label("Медиатека / Фото", systemImage: "photo.on.rectangle") }
                    Button(action: { showDocumentPicker = true }) { Label("Выбрать файл / Документ", systemImage: "doc.badge.plus") }
                } label: { Image(systemName: "plus.circle.fill").font(.system(size: 26)).foregroundColor(viewModel.provider == .gemini ? .blue : .purple) }
                
                TextField("Спросите ИИ...", text: $inputText).textFieldStyle(PlainTextFieldStyle()).padding(14).background(Color(.systemGray6)).cornerRadius(22).disableAutocorrection(true)
                
                Button(action: sendMessageAction) {
                    Image(systemName: "paperplane.fill").font(.system(size: 18, weight: .bold)).foregroundColor(.white).padding(12).background((inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingAttachments.isEmpty) ? Color.gray.opacity(0.5) : (viewModel.provider == .gemini ? Color.blue : Color.purple)).clipShape(Circle())
                }.disabled((inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingAttachments.isEmpty) || viewModel.isLoading)
            }.padding().background(Color(.systemBackground))
        }
        .sheet(isPresented: $showImagePicker) { ImagePicker { image, data, fileName in pendingAttachments.append(PendingAttachment(fileName: fileName, mimeType: "image/jpeg", data: data, image: image)) } }
        .sheet(isPresented: $showDocumentPicker) { DocumentPicker { url, data, fileName in
            let mime = getMimeType(for: url); let uiImage = mime.hasPrefix("image/") ? UIImage(data: data) : nil
            pendingAttachments.append(PendingAttachment(fileName: fileName, mimeType: mime, data: data, image: uiImage))
        } }
    }
    
    private func getMimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "pdf": return "application/pdf"
        case "txt": return "text/plain"
        case "json": return "application/json"
        case "html": return "text/html"
        case "css": return "text/css"
        case "js": return "application/javascript"
        default: return "application/octet-stream"
        }
    }
    
    private func sendMessageAction() {
        let textToSend = inputText; inputText = ""
        var savedAttachments: [ChatAttachment] = []
        for pending in pendingAttachments {
            if let uniqueName = viewModel.saveFileToDisk(data: pending.data, fileName: pending.fileName) {
                savedAttachments.append(ChatAttachment(fileName: uniqueName, mimeType: pending.mimeType, fileURLString: uniqueName))
            }
        }
        pendingAttachments = []
        Task { await viewModel.sendMessage(text: textToSend, attachments: savedAttachments) }
    }
    
    private func scrollToBottom(proxy: ScrollViewProxy, session: ChatSession) {
        let isActivelyStreaming = viewModel.isTyping && session.messages.last?.role == .model && !(session.messages.last?.content.isEmpty ?? true)
        if isActivelyStreaming {
            if let lastMessage = session.messages.last { proxy.scrollTo(lastMessage.id, anchor: .bottom) }
        } else {
            withAnimation(.easeOut(duration: 0.25)) {
                if viewModel.errorMessage != nil { proxy.scrollTo("errorIndicator", anchor: .bottom) }
                else if viewModel.isLoading && (session.messages.last?.role == .user || session.messages.last?.content.isEmpty == true) { proxy.scrollTo("loadingIndicator", anchor: .bottom) }
                else if let lastMessage = session.messages.last { proxy.scrollTo(lastMessage.id, anchor: .bottom) }
            }
        }
    }
}

// MARK: - Пузырьки сообщений

struct MessageBubble: View {
    let message: ChatMessage
    @State private var isCopied: Bool = false
    
    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 50)
                VStack(alignment: .trailing, spacing: 8) {
                    if let attachments = message.attachments, !attachments.isEmpty {
                        ForEach(attachments) { attachment in AttachmentBubbleView(attachment: attachment) }
                    }
                    if !message.content.isEmpty {
                        MarkdownView(text: message.content, textColor: .white).padding(14).background(Color.blue).cornerRadius(18, corners: [.topLeft, .topRight, .bottomLeft])
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if let attachments = message.attachments, !attachments.isEmpty {
                        ForEach(attachments) { attachment in AttachmentBubbleView(attachment: attachment) }
                    }
                    if !message.content.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            MarkdownView(text: message.content, textColor: .primary)
                            HStack {
                                Button(action: {
                                    UIPasteboard.general.string = message.content; withAnimation { isCopied = true }; UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { isCopied = false } }
                                }) { HStack(spacing: 4) { Image(systemName: isCopied ? "checkmark" : "doc.on.doc"); Text(isCopied ? "Скопировано" : "Копировать") }.font(.system(size: 10, weight: .medium)).foregroundColor(isCopied ? .green : .secondary) }
                                Spacer()
                                Text(message.timestamp, style: .time).font(.system(size: 9)).foregroundColor(.secondary)
                            }.padding(.top, 4)
                        }.padding(14).background(Color(.secondarySystemBackground)).cornerRadius(18, corners: [.topLeft, .topRight, .bottomRight])
                    }
                }
                Spacer(minLength: 50)
            }
        }.padding(.horizontal)
    }
}

struct AttachmentBubbleView: View {
    let attachment: ChatAttachment
    var body: some View {
        Group {
            if attachment.mimeType.hasPrefix("image/"), let url = attachment.localURL, let data = try? Data(contentsOf: url), let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage).resizable().aspectRatio(contentMode: .fill).frame(maxWidth: 220, maxHeight: 180).cornerRadius(12).clipped()
            } else {
                HStack(spacing: 8) {
                    ZStack { Color.blue.opacity(0.1); Image(systemName: "doc.fill").foregroundColor(.blue).font(.system(size: 16)) }.frame(width: 36, height: 36).cornerRadius(8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(attachment.fileName.components(separatedBy: "_").dropFirst().joined(separator: "_")).font(.system(size: 12, weight: .medium)).foregroundColor(.primary).lineLimit(1).frame(maxWidth: 160)
                        Text(attachment.mimeType.uppercased()).font(.system(size: 8)).foregroundColor(.secondary)
                    }
                }.padding(8).background(Color(.systemGray5)).cornerRadius(10)
            }
        }
    }
}

// MARK: - Вспомогательные расширения

extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View { clipShape(RoundedCorner(radius: radius, corners: corners)) }
    func hideKeyboard() { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity; var corners: UIRectCorner = .allCorners
    func path(in rect: CGRect) -> Path { return Path(UIBezierPath(roundedRect: rect, byRoundingCorners: corners, cornerRadii: CGSize(width: radius, height: radius)).cgPath) }
}
