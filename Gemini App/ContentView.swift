import SwiftUI
import Combine
import UniformTypeIdentifiers
import UIKit // Добавлено для работы с UIPasteboard

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

// MARK: - Доступные модели Gemini

struct GeminiModelInfo: Identifiable, Hashable {
    let id: String
    let displayName: String
    let description: String
}

/// Актуальный список поддерживаемых моделей Gemini
let availableModels = [
    GeminiModelInfo(id: "gemini-3.5-flash", displayName: "Gemini 3.5 Flash", description: "Быстрая и умная, идеальна для повседневного общения"),
    GeminiModelInfo(id: "gemini-3.1-pro-preview", displayName: "Gemini 3.1 Pro", description: "Для сложных рассуждений, программирования и логики"),
    GeminiModelInfo(id: "gemini-3.1-flash-lite", displayName: "Gemini 3.1 Flash-Lite", description: "Максимальная скорость ответа на простые запросы"),
    GeminiModelInfo(id: "gemini-2.5-pro", displayName: "Gemini 2.5 Pro", description: "Глубокий анализ (предыдущее поколение)"),
    GeminiModelInfo(id: "gemini-2.5-flash", displayName: "Gemini 2.5 Flash", description: "Универсальный баланс (предыдущее поколение)")
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
    
    // API-ключ сохраняется в защищенном хранилище UserDefaults
    @AppStorage("gemini_api_key") var apiKey: String = ""
    
    // Выбранная по умолчанию модель
    @AppStorage("gemini_selected_model") var selectedModel: String = "gemini-3.5-flash"
    
    // Настройки генерации
    @AppStorage("gemini_temperature") var temperature: Double = 0.7
    @AppStorage("gemini_system_prompt") var systemPrompt: String = ""
    
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
    
    /// Текущая активная сессия чата
    var currentSession: ChatSession? {
        sessions.first(where: { $0.id == currentSessionId })
    }
    
    
    /// Загрузка сессий из памяти устройства
    func loadSessions() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsSessionsKey) else { return }
        if let decoded = try? JSONDecoder().decode([ChatSession].self, from: data) {
            self.sessions = decoded
        }
    }
    
    /// Сохранение сессий на устройство
    func saveSessions() {
        if let encoded = try? JSONEncoder().encode(sessions) {
            UserDefaults.standard.set(encoded, forKey: userDefaultsSessionsKey)
        }
    }
    
    /// Загрузка сохраненных системных промптов
    func loadSavedPrompts() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsPromptsKey) else { return }
        if let decoded = try? JSONDecoder().decode([SavedPrompt].self, from: data) {
            self.savedPrompts = decoded
        }
    }
    
    /// Сохранение нового системного промпта
    func saveNewPrompt(title: String, text: String) {
        let newPrompt = SavedPrompt(title: title, text: text)
        savedPrompts.append(newPrompt)
        if let encoded = try? JSONEncoder().encode(savedPrompts) {
            UserDefaults.standard.set(encoded, forKey: userDefaultsPromptsKey)
        }
    }
    
    /// Удаление системного промпта
    func deleteSavedPrompt(at offsets: IndexSet) {
        savedPrompts.remove(atOffsets: offsets)
        if let encoded = try? JSONEncoder().encode(savedPrompts) {
            UserDefaults.standard.set(encoded, forKey: userDefaultsPromptsKey)
        }
    }
    
    /// Создание нового диалога
    func createNewSession() {
        let newSession = ChatSession(
            title: "Новый чат \(sessions.count + 1)",
            messages: [],
            createdAt: Date()
        )
        sessions.insert(newSession, at: 0)
        currentSessionId = newSession.id
        saveSessions()
    }
    
    /// Переключение на выбранный сеанс
    func selectSession(_ id: UUID) {
        currentSessionId = id
    }
    
    /// Удаление диалога
    func deleteSession(at offsets: IndexSet) {
        sessions.remove(atOffsets: offsets)
        if let first = sessions.first {
            currentSessionId = first.id
        } else {
            createNewSession()
        }
        saveSessions()
    }
    
    /// Сохранение бинарных данных во внутреннюю директорию документов
    func saveFileToDisk(data: Data, fileName: String) -> String? {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        guard let documentsDirectory = paths.first else { return nil }
        
        // Предотвращаем перезапись файлов с одинаковыми именами, добавляя уникальный префикс
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
    
    /// Проверка действия и ограничений API-ключа
    func validateApiKey(_ keyToCheck: String) async {
        let trimmedKey = keyToCheck.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            await MainActor.run {
                self.keyValidationStatus = .invalid(reason: "Ключ не может быть пустым.")
            }
            return
        }
        
        await MainActor.run {
            self.isCheckingKey = true
            self.keyValidationStatus = .unchecked
        }
        
        // Легковесный тестовый GET-запрос для быстрой валидации ключа и его лимитов
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models?key=\(trimmedKey)"
        guard let url = URL(string: urlString) else {
            await MainActor.run {
                self.isCheckingKey = false
                self.keyValidationStatus = .invalid(reason: "Некорректный формат URL проверки.")
            }
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            
            if httpResponse.statusCode == 200 {
                await MainActor.run {
                    self.isCheckingKey = false
                    self.keyValidationStatus = .valid
                }
            } else {
                var parsedErrorMessage = "Код ошибки: \(httpResponse.statusCode)"
                var errorStatusString = ""
                
                if let errorJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errorDetails = errorJSON["error"] as? [String: Any] {
                    if let message = errorDetails["message"] as? String {
                        parsedErrorMessage = message
                    }
                    if let status = errorDetails["status"] as? String {
                        errorStatusString = status
                    }
                }
                
                await MainActor.run {
                    self.isCheckingKey = false
                    
                    if httpResponse.statusCode == 429 || errorStatusString == "RESOURCE_EXHAUSTED" {
                        self.keyValidationStatus = .rateLimited(reason: "Лимит запросов исчерпан. Пожалуйста, подождите или смените тариф ключа (Бесплатный лимит: 15 RPM). Подробнее: \(parsedErrorMessage)")
                    } else {
                        self.keyValidationStatus = .invalid(reason: "Ошибка проверки ключа! Проверьте правильность ввода. \(parsedErrorMessage)")
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
    
    /// Отправка сообщения в Gemini
    func sendMessage(text: String, attachments: [ChatAttachment]) async {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Разрешаем отправку пустого текста, если прикреплен хотя бы один файл
        guard !trimmedText.isEmpty || !attachments.isEmpty else { return }
        
        guard !apiKey.isEmpty else {
            await MainActor.run {
                self.errorMessage = "Пожалуйста, укажите ваш API-ключ в настройках."
            }
            return
        }
        
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == currentSessionId }) else { return }
        
        // 1. Создаем сообщение пользователя локально
        let userMessage = ChatMessage(role: .user, content: trimmedText, timestamp: Date(), attachments: attachments)
        
        // 2. Подготавливаем историю диалога для API (до добавления плейсхолдера для ответа)
        let apiMessages = prepareApiMessages(for: sessionIndex, adding: userMessage)
        
        // Подготавливаем ID для будущего ответа модели
        let modelMessageId = UUID()
        
        await MainActor.run {
            // Добавляем сообщение пользователя в UI
            self.sessions[sessionIndex].messages.append(userMessage)
            
            // Автоматическое переименование пустого чата по первому сообщению
            if self.sessions[sessionIndex].title.hasPrefix("Новый чат") {
                let preview = trimmedText.isEmpty ? "Файл/Изображение" : String(trimmedText.prefix(25))
                self.sessions[sessionIndex].title = preview + (trimmedText.count > 25 ? "..." : "")
            }
            
            // Сразу добавляем пустой баббл для стриминга ответа
            let placeholderMessage = ChatMessage(id: modelMessageId, role: .model, content: "", timestamp: Date(), attachments: nil)
            self.sessions[sessionIndex].messages.append(placeholderMessage)
            
            self.isLoading = true
            self.errorMessage = nil
            self.saveSessions()
        }
        
        // 3. Выполняем сетевой запрос (стриминг)
        await executeApiCall(apiMessages: apiMessages, sessionIndex: sessionIndex, targetMessageId: modelMessageId)
    }
    
    /// Повторная отправка последнего сообщения при возникновении ошибки
    func retryLastMessage() async {
        guard !apiKey.isEmpty else {
            await MainActor.run {
                self.errorMessage = "Пожалуйста, укажите ваш API-ключ в настройках."
            }
            return
        }
        
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == currentSessionId }) else { return }
        
        // Если последнее сообщение от модели (прерванное/с ошибкой), удаляем его
        if let lastMsg = sessions[sessionIndex].messages.last, lastMsg.role == .model {
            await MainActor.run {
                self.sessions[sessionIndex].messages.removeLast()
            }
        }
        
        // Убеждаемся, что теперь последнее сообщение было отправлено пользователем
        guard sessions[sessionIndex].messages.last?.role == .user else { return }
        
        // Формируем историю диалога на основе текущих сообщений
        let apiMessages = prepareApiMessages(for: sessionIndex, adding: nil)
        
        let modelMessageId = UUID()
        
        await MainActor.run {
            self.isLoading = true
            self.errorMessage = nil
            
            // Добавляем пустой плейсхолдер для нового ответа
            let placeholderMessage = ChatMessage(id: modelMessageId, role: .model, content: "", timestamp: Date(), attachments: nil)
            self.sessions[sessionIndex].messages.append(placeholderMessage)
        }
        
        // Повторно запускаем сетевой запрос
        await executeApiCall(apiMessages: apiMessages, sessionIndex: sessionIndex, targetMessageId: modelMessageId)
    }
    
    /// Вспомогательный метод формирования массива объектов для API Gemini
    private func prepareApiMessages(for sessionIndex: Int, adding newMessage: ChatMessage?) -> [GeminiContent] {
        var allMessages = sessions[sessionIndex].messages
        if let newMsg = newMessage {
            allMessages.append(newMsg)
        }
        
        return allMessages.map { msg -> GeminiContent in
            let apiRole = msg.role == .user ? "user" : "model"
            var parts: [GeminiPart] = []
            
            // Если есть текстовый контент, добавляем его в виде первой части
            if !msg.content.isEmpty {
                parts.append(GeminiPart(text: msg.content, inlineData: nil))
            }
            
            // Если есть вложения, кодируем их в Base64 и прикрепляем как inlineData части
            if let messageAttachments = msg.attachments {
                for attachment in messageAttachments {
                    if let url = attachment.localURL,
                       let fileData = try? Data(contentsOf: url) {
                        let base64String = fileData.base64EncodedString()
                        let inline = GeminiInlineData(mimeType: attachment.mimeType, data: base64String)
                        parts.append(GeminiPart(text: nil, inlineData: inline))
                    }
                }
            }
            
            // Защита от пустых блоков
            if parts.isEmpty {
                parts.append(GeminiPart(text: " ", inlineData: nil))
            }
            
            return GeminiContent(role: apiRole, parts: parts)
        }
    }
    
    /// Выполнение потокового (SSE) сетевого запроса к API Gemini (iOS 15+)
    private func executeApiCall(apiMessages: [GeminiContent], sessionIndex: Int, targetMessageId: UUID) async {
        let sysInstruct = systemPrompt.isEmpty ? nil : GeminiSystemInstruction(parts: [GeminiPart(text: systemPrompt, inlineData: nil)])
        let genConfig = GeminiGenerationConfig(temperature: temperature)
        
        let requestBody = GeminiRequest(contents: apiMessages, systemInstruction: sysInstruct, generationConfig: genConfig)
        
        // Используем эндпоинт streamGenerateContent для стриминга (с alt=sse)
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(selectedModel):streamGenerateContent?alt=sse&key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            await MainActor.run {
                self.isLoading = false
                self.errorMessage = "Некорректный URL API"
                self.sessions[sessionIndex].messages.removeAll(where: { $0.id == targetMessageId })
            }
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        await MainActor.run {
            self.textBuffer = ""
            self.startSmoothTyping(sessionIndex: sessionIndex, messageId: targetMessageId)
        }
        
        do {
            request.httpBody = try JSONEncoder().encode(requestBody)
            
            // Используем асинхронный байтовый стрим (доступно с iOS 15)
            let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            
            // Если статус не 200, читаем все тело ответа, чтобы получить сообщение об ошибке
            if httpResponse.statusCode != 200 {
                var errorData = Data()
                for try await byte in asyncBytes {
                    errorData.append(byte)
                }
                
                var detailedError = "Ошибка сервера (Код \(httpResponse.statusCode))"
                var statusString = ""
                
                if let errorJSON = try? JSONSerialization.jsonObject(with: errorData) as? [String: Any],
                   let errorDetails = errorJSON["error"] as? [String: Any] {
                    if let message = errorDetails["message"] as? String {
                        detailedError = message
                    }
                    if let status = errorDetails["status"] as? String {
                        statusString = status
                    }
                }
                
                if httpResponse.statusCode == 429 || statusString == "RESOURCE_EXHAUSTED" {
                    throw NSError(domain: "GeminiError", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Превышен лимит запросов в минуту (Rate Limit). Пожалуйста, подождите немного перед отправкой следующего сообщения."])
                } else if httpResponse.statusCode == 400 && detailedError.contains("API key") {
                    throw NSError(domain: "GeminiError", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Указан недействительный API-ключ. Проверьте настройки приложения."])
                } else {
                    throw NSError(domain: "GeminiError", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: detailedError])
                }
            }
            
            var hasReceivedContent = false
            
            // Читаем поток по строкам (SSE)
            for try await line in asyncBytes.lines {
                guard line.hasPrefix("data: ") else { continue }
                
                let jsonString = String(line.dropFirst(6))
                
                if jsonString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                if jsonString == "[DONE]" { break } // Маркер завершения стрима
                
                if let data = jsonString.data(using: .utf8) {
                    let decodedResponse = try JSONDecoder().decode(GeminiResponse.self, from: data)
                    
                    if let textPiece = decodedResponse.candidates?.first?.content?.parts.first?.text {
                        hasReceivedContent = true
                        // Добавляем текст в буфер для плавного рендеринга
                        await MainActor.run {
                            self.textBuffer += textPiece
                        }
                    }
                }
            }
            
            if !hasReceivedContent {
                throw NSError(domain: "GeminiError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Пустой ответ от модели. Попробуйте еще раз или проверьте параметры."])
            }
            
            await MainActor.run {
                self.isLoading = false
            }
            
        } catch {
            await MainActor.run {
                self.isLoading = false
                self.errorMessage = error.localizedDescription
                // Если произошла ошибка до получения текста, удаляем пустой баббл
                if let msgIndex = self.sessions[sessionIndex].messages.firstIndex(where: { $0.id == targetMessageId }),
                   self.sessions[sessionIndex].messages[msgIndex].content.isEmpty {
                    self.sessions[sessionIndex].messages.remove(at: msgIndex)
                }
            }
        }
    }
    
    /// Запуск цикла плавного посимвольного вывода текста (эффект печатной машинки)
    private func startSmoothTyping(sessionIndex: Int, messageId: UUID) {
        displayTask?.cancel()
        
        displayTask = Task { @MainActor in
            self.isTyping = true
            
            while !Task.isCancelled {
                if !self.textBuffer.isEmpty {
                    // Используем фиксированную скорость (2 символа за такт) для плавности
                    // При большом накоплении буфера пропорционально увеличиваем порцию, чтобы не отставать
                    let takeCount = max(2, self.textBuffer.count / 8)
                    let chunk = String(self.textBuffer.prefix(takeCount))
                    self.textBuffer.removeFirst(chunk.count)
                    
                    if let msgIndex = self.sessions[sessionIndex].messages.firstIndex(where: { $0.id == messageId }) {
                        self.sessions[sessionIndex].messages[msgIndex].content += chunk
                    }
                } else if !self.isLoading {
                    // Сетевой запрос завершен и буфер пуст
                    break
                }
                
                // Задержка ~30 мс для частоты обновления ~33 кадра в секунду
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
            
            self.isTyping = false
            self.saveSessions()
        }
    }
}


// MARK: - Парсинг и Рендеринг Markdown (iOS 15+)

/// Типы блоков, на которые разделяется входящее сообщение (кастомный структурный парсер)
enum MarkdownBlock: Identifiable, Equatable {
    var id: UUID { UUID() }
    
    case text(AttributedString)
    case header(text: AttributedString, level: Int)
    case quote(AttributedString)
    case codeBlock(code: String, language: String)
    case divider
}

/// Продвинутый кастомный парсер Markdown, исправляющий ограничения встроенного парсера iOS 15
struct MarkdownParser {
    
    /// Парсит исходный текст в массив красивых визуальных блоков (заголовки, цитаты, код, текст)
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = text.components(separatedBy: .newlines)
        
        var currentTextLines: [String] = []
        var currentQuoteLines: [String] = []
        var isInsideCodeBlock = false
        var codeLanguage = ""
        
        // Вспомогательная функция для сброса накопившегося обычного текста
        func flushText() {
            let joined = currentTextLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                blocks.append(.text(parseInline(joined)))
            }
            currentTextLines.removeAll()
        }
        
        // Вспомогательная функция для сброса накопившейся цитаты
        func flushQuote() {
            let joined = currentQuoteLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                blocks.append(.quote(parseInline(joined)))
            }
            currentQuoteLines.removeAll()
        }
        
        for line in lines {
            // 1. Блоки кода ( ``` )
            if line.hasPrefix("```") {
                if isInsideCodeBlock {
                    // Закрываем блок кода
                    blocks.append(.codeBlock(code: currentTextLines.joined(separator: "\n"), language: codeLanguage))
                    currentTextLines.removeAll()
                    isInsideCodeBlock = false
                } else {
                    // Открываем блок кода
                    flushText()
                    flushQuote()
                    isInsideCodeBlock = true
                    codeLanguage = String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                continue
            }
            
            // Если мы внутри кода, просто копим строки и игнорируем остальной синтаксис
            if isInsideCodeBlock {
                currentTextLines.append(line)
                continue
            }
            
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            
            // 2. Горизонтальные линии (---)
            if trimmedLine == "---" || trimmedLine == "***" || trimmedLine == "___" {
                flushText()
                flushQuote()
                blocks.append(.divider)
                continue
            }
            
            // 3. Заголовки (H1 - H3)
            if line.hasPrefix("# ") {
                flushText()
                flushQuote()
                blocks.append(.header(text: parseInline(String(line.dropFirst(2))), level: 1))
                continue
            } else if line.hasPrefix("## ") {
                flushText()
                flushQuote()
                blocks.append(.header(text: parseInline(String(line.dropFirst(3))), level: 2))
                continue
            } else if line.hasPrefix("### ") {
                flushText()
                flushQuote()
                blocks.append(.header(text: parseInline(String(line.dropFirst(4))), level: 3))
                continue
            }
            
            // 4. Цитаты (>)
            if line.hasPrefix(">") {
                flushText()
                // Убираем символ > и возможный пробел после него
                let quoteContent = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                currentQuoteLines.append(quoteContent)
                continue
            } else {
                // Если строка не цитата, то сбрасываем накопленные цитаты
                flushQuote()
            }
            
            // 5. Обычный текст (включая списки *, -, 1.)
            currentTextLines.append(line)
        }
        
        // В конце цикла не забываем сбросить остатки
        flushText()
        flushQuote()
        
        return blocks
    }
    
    /// Преобразует строчный Markdown во встроенный в iOS 15 AttributedString, строго сохраняя переносы строк
    private static func parseInline(_ text: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        // ВАЖНО: Только режим inline (сохранение оригинальных переносов \n, чтобы текст не "сбивался в кучу")
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        
        if let attrString = try? AttributedString(markdown: text, options: options) {
            return attrString
        }
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
                    Text(attrString)
                        .font(.body)
                        .foregroundColor(textColor)
                        .tint(textColor == .white ? .white : .blue) // Подстраиваем цвет ссылок
                        .textSelection(.enabled) // Копирование текста (iOS 15+)
                    
                case .header(let attrString, let level):
                    Text(attrString)
                        // Динамический размер в зависимости от уровня заголовка
                        .font(.system(size: level == 1 ? 22 : (level == 2 ? 19 : 17), weight: .bold))
                        .foregroundColor(textColor)
                        .tint(textColor == .white ? .white : .blue)
                        .textSelection(.enabled)
                        .padding(.top, 6)
                        .padding(.bottom, 2)
                    
                case .quote(let attrString):
                    HStack(spacing: 12) {
                        // Вертикальная полоса цитаты
                        Rectangle()
                            .fill(textColor.opacity(0.3))
                            .frame(width: 3)
                        
                        Text(attrString)
                            .font(.body)
                            .foregroundColor(textColor.opacity(0.8)) // Слегка тусклый цвет для цитат
                            .tint(textColor == .white ? .white : .blue)
                            .textSelection(.enabled)
                    }
                    .fixedSize(horizontal: false, vertical: true) // Защита от обрезания многострочных цитат
                    .padding(.vertical, 4)
                    
                case .codeBlock(let code, let language):
                    CodeBlockView(code: code, language: language)
                        .padding(.vertical, 4)
                        
                case .divider:
                    Divider()
                        .background(textColor.opacity(0.3))
                        .padding(.vertical, 8)
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
            // Панель заголовка блока кода
            HStack {
                Text(language.isEmpty ? "CODE" : language.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Button(action: {
                    UIPasteboard.general.string = code
                    withAnimation {
                        isCopied = true
                    }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation {
                            isCopied = false
                        }
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        Text(isCopied ? "Скопировано" : "Копировать")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(isCopied ? .green : .blue)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.systemGray5))
            
            // Область самого кода с горизонтальным скроллом
            ScrollView(.horizontal, showsIndicators: true) {
                Text(code)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundColor(Color(.label))
                    .padding(12)
                    .textSelection(.enabled)
            }
            .background(Color(.systemGray6))
        }
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(.systemGray4), lineWidth: 1)
        )
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
                .navigationTitle(viewModel.currentSession?.title ?? "Чат с Gemini")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    // Кнопка открытия истории слева
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(action: {
                            showingHistory = true
                        }) {
                            HStack(spacing: 5) {
                                Image(systemName: "list.bullet")
                                Text("История")
                                    .font(.subheadline)
                            }
                        }
                    }
                    
                    // Подзаголовок с названием модели по центру
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 2) {
                            Text(viewModel.currentSession?.title ?? "Чат с Gemini")
                                .font(.headline)
                            if let modelName = availableModels.first(where: { $0.id == viewModel.selectedModel })?.displayName {
                                Text(modelName)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                    
                    // Кнопки управления справа
                    ToolbarItem(placement: .navigationBarTrailing) {
                        HStack(spacing: 16) {
                            Button(action: {
                                viewModel.createNewSession()
                            }) {
                                Image(systemName: "square.and.pencil")
                            }
                            
                            Button(action: {
                                showingSettings = true
                            }) {
                                Image(systemName: "gearshape.fill")
                            }
                        }
                    }
                }
        }
        .navigationViewStyle(.stack) // Принудительный стек-стиль во избежание бага с боковой панелью на iPhone
        .sheet(isPresented: $showingHistory) {
            HistoryView(viewModel: viewModel, isPresented: $showingHistory)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(viewModel: viewModel, isPresented: $showingSettings)
        }
    }
}


// MARK: - UIImagePickerController Wrapper для iOS 15

struct ImagePicker: UIViewControllerRepresentable {
    let onPick: (UIImage, Data, String) -> Void
    
    @Environment(\.presentationMode) private var presentationMode
    
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: ImagePicker
        
        init(_ parent: ImagePicker) {
            self.parent = parent
        }
        
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let image = info[.originalImage] as? UIImage {
                // Изменяем разрешение изображения, чтобы уменьшить вес отправляемых данных
                let resized = resizeImage(image: image, targetSize: CGSize(width: 1200, height: 1200))
                if let jpegData = resized.jpegData(compressionQuality: 0.8) {
                    let fileName = "photo_\(Int(Date().timeIntervalSince1970)).jpg"
                    parent.onPick(image, jpegData, fileName)
                }
            }
            parent.presentationMode.wrappedValue.dismiss()
        }
        
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.presentationMode.wrappedValue.dismiss()
        }
        
        private func resizeImage(image: UIImage, targetSize: CGSize) -> UIImage {
            let size = image.size
            let widthRatio  = targetSize.width  / size.width
            let heightRatio = targetSize.height / size.height
            let newSize = widthRatio > heightRatio ?
                CGSize(width: size.width * heightRatio, height: size.height * heightRatio) :
                CGSize(width: size.width * widthRatio,  height: size.height * widthRatio)
            let rect = CGRect(origin: .zero, size: newSize)
            UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
            image.draw(in: rect)
            let newImage = UIGraphicsGetImageFromCurrentImageContext()
            UIGraphicsEndImageContext()
            return newImage ?? image
        }
    }
}


// MARK: - UIDocumentPickerViewController Wrapper для iOS 15

struct DocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL, Data, String) -> Void
    
    @Environment(\.presentationMode) private var presentationMode
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data, .content])
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPicker
        
        init(_ parent: DocumentPicker) {
            self.parent = parent
        }
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            
            // Запрашиваем доступ к файлу, полученному из файловой системы устройства
            let shouldStopAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if shouldStopAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            
            if let data = try? Data(contentsOf: url) {
                let fileName = url.lastPathComponent
                parent.onPick(url, data, fileName)
            }
            
            parent.presentationMode.wrappedValue.dismiss()
        }
        
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.presentationMode.wrappedValue.dismiss()
        }
    }
}


// MARK: - Экран истории чатов (HistoryView)

struct HistoryView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Binding var isPresented: Bool
    
    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Сохраненные диалоги")) {
                    if viewModel.sessions.isEmpty {
                        Text("История пуста")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(viewModel.sessions) { session in
                            Button(action: {
                                viewModel.selectSession(session.id)
                                isPresented = false
                            }) {
                                HStack(spacing: 12) {
                                    Image(systemName: "bubble.left.and.bubble.right.fill")
                                        .foregroundColor(.blue)
                                        .font(.body)
                                    
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(session.title)
                                            .font(.system(size: 17, weight: .semibold))
                                            .foregroundColor(.primary)
                                            .lineLimit(1)
                                        
                                        if let lastMsg = session.messages.last {
                                            Text(lastMsg.content.isEmpty ? "Файл / Изображение" : lastMsg.content)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                                .lineLimit(1)
                                        } else {
                                            Text("Пустой чат")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    
                                    Spacer()
                                    
                                    if session.id == viewModel.currentSessionId {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.green)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .onDelete(perform: viewModel.deleteSession)
                    }
                }
            }
            .listStyle(InsetGroupedListStyle())
            .navigationTitle("История чатов")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Закрыть") {
                        isPresented = false
                    }
                }
            }
        }
    }
}


// MARK: - Экран настроек (SettingsView)

struct SettingsView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Binding var isPresented: Bool
    
    @State private var tempKey: String = ""
    @State private var tempModel: String = "gemini-3.5-flash"
    @State private var tempTemperature: Double = 0.7
    @State private var tempSystemPrompt: String = ""
    
    // Стейты для сохранения системного промпта
    @State private var showingSavePromptAlert = false
    @State private var newPromptTitle = ""
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("API-КЛЮЧ GEMINI"), footer: Text("Бесплатный ключ на aistudio.google.com имеет лимиты: 15 запросов в минуту (RPM), 1500 запросов в день (RPD).")) {
                    HStack(spacing: 12) {
                        SecureField("Введите ваш API-ключ", text: $tempKey)
                            .disableAutocorrection(true)
                            .autocapitalization(.none)
                            .onChange(of: tempKey) { _ in
                                // Сбрасываем статус при ручном изменении текста ключа
                                viewModel.keyValidationStatus = .unchecked
                            }
                        
                        if viewModel.isCheckingKey {
                            ProgressView()
                                .frame(width: 24, height: 24)
                        } else {
                            Button(action: {
                                Task {
                                    await viewModel.validateApiKey(tempKey)
                                }
                            }) {
                                Image(systemName: "arrow.clockwise.circle.fill")
                                    .font(.system(size: 22))
                                    .foregroundColor(.blue)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    
                    // Вывод статуса проверки ключа
                    switch viewModel.keyValidationStatus {
                    case .unchecked:
                        EmptyView()
                    case .valid:
                        HStack {
                            Image(systemName: "checkmark.shield.fill")
                                .foregroundColor(.green)
                            Text("Ключ активен! Ограничения в порядке.")
                                .font(.footnote)
                                .foregroundColor(.green)
                        }
                        .padding(.top, 2)
                    case .invalid(let reason):
                        HStack(alignment: .top) {
                            Image(systemName: "exclamationmark.shield.fill")
                                .foregroundColor(.red)
                            Text(reason)
                                .font(.footnote)
                                .foregroundColor(.red)
                        }
                        .padding(.top, 2)
                    case .rateLimited(let reason):
                        HStack(alignment: .top) {
                            Image(systemName: "clock.badge.exclamationmark.fill")
                                .foregroundColor(.orange)
                            Text(reason)
                                .font(.footnote)
                                .foregroundColor(.orange)
                        }
                        .padding(.top, 2)
                    }
                    
                    Link(destination: URL(string: "https://aistudio.google.com/")!) {
                        HStack {
                            Text("Получить бесплатный API ключ")
                                .font(.footnote)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                        }
                    }
                }
                
                Section(header: Text("ВЫБОР МОДЕЛИ")) {
                    ForEach(availableModels, id: \.id) { model in
                        Button(action: {
                            tempModel = model.id
                        }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(model.displayName)
                                        .foregroundColor(.primary)
                                        .font(.system(size: 17, weight: tempModel == model.id ? .semibold : .regular))
                                    
                                    Text(model.description)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.leading)
                                }
                                Spacer()
                                if tempModel == model.id {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                        .font(.system(size: 14, weight: .bold))
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                
                Section(header: Text("НАСТРОЙКИ ГЕНЕРАЦИИ")) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Температура ответа:")
                            Spacer()
                            Text(String(format: "%.1f", tempTemperature))
                                .fontWeight(.bold)
                        }
                        Slider(value: $tempTemperature, in: 0.0...2.0, step: 0.1)
                        Text("Меньше — более точные ответы, больше — более креативные.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                
                Section(header: Text("СИСТЕМНЫЙ ПРОМПТ")) {
                    VStack(alignment: .leading, spacing: 4) {
                        TextEditor(text: $tempSystemPrompt)
                            .frame(minHeight: 80)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color(.systemGray4), lineWidth: 1)
                            )
                        Text("Инструкции, определяющие поведение нейросети (роль, стиль общения).")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                    
                    Button(action: {
                        newPromptTitle = ""
                        showingSavePromptAlert = true
                    }) {
                        HStack {
                            Image(systemName: "square.and.arrow.down")
                            Text("Сохранить текущий промпт")
                        }
                    }
                    .disabled(tempSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                
                Section(header: Text("СОХРАНЕННЫЕ ПРОМПТЫ")) {
                    if viewModel.savedPrompts.isEmpty {
                        Text("Нет сохраненных промптов")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(viewModel.savedPrompts) { prompt in
                            Button(action: {
                                tempSystemPrompt = prompt.text
                            }) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(prompt.title)
                                            .foregroundColor(.primary)
                                            .font(.system(size: 16, weight: .medium))
                                        Text(prompt.text)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.up.doc")
                                        .foregroundColor(.blue)
                                        .font(.system(size: 14))
                                }
                            }
                        }
                        .onDelete(perform: viewModel.deleteSavedPrompt)
                    }
                }
                
                Section(footer: Text("Этот ключ и настройки сохраняются только локально на вашем устройстве в зашифрованном виде.")) {
                    Button(action: saveSettings) {
                        Text("Сохранить настройки")
                            .frame(maxWidth: .infinity)
                            .foregroundColor(.white)
                            .font(.system(size: 17, weight: .semibold))
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Отмена") {
                        isPresented = false
                    }
                }
            }
            .onAppear {
                tempKey = viewModel.apiKey
                tempModel = viewModel.selectedModel
                tempTemperature = viewModel.temperature
                tempSystemPrompt = viewModel.systemPrompt
                
                // Автоматическая фоновая проверка при входе в настройки
                if !tempKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Task {
                        await viewModel.validateApiKey(tempKey)
                    }
                }
            }
            .alert("Сохранить промпт", isPresented: $showingSavePromptAlert) {
                TextField("Название промпта", text: $newPromptTitle)
                Button("Отмена", role: .cancel) { }
                Button("Сохранить") {
                    let title = newPromptTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Без названия" : newPromptTitle
                    viewModel.saveNewPrompt(title: title, text: tempSystemPrompt)
                }
            } message: {
                Text("Введите название для сохранения текущего промпта.")
            }
        }
    }
    
    private func saveSettings() {
        viewModel.apiKey = tempKey
        viewModel.selectedModel = tempModel
        viewModel.temperature = tempTemperature
        viewModel.systemPrompt = tempSystemPrompt
        isPresented = false
    }
}


// MARK: - Модель временного вложения в процессе подготовки

struct PendingAttachment: Identifiable {
    let id = UUID()
    let fileName: String
    let mimeType: String
    let data: Data
    let image: UIImage?
}

// MARK: - Окно самого диалога (Чат)

struct ChatRoomView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Binding var inputText: String
    
    // Стейты управления вложениями
    @State private var showImagePicker = false
    @State private var showDocumentPicker = false
    @State private var pendingAttachments: [PendingAttachment] = []
    
    var body: some View {
        VStack(spacing: 0) {
            if let session = viewModel.currentSession {
                if session.messages.isEmpty {
                    // Приветственный экран, если сообщений нет
                    VStack(spacing: 20) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 70))
                            .foregroundColor(.blue.opacity(0.85))
                        
                        Text("Привет! Я Gemini")
                            .font(.title)
                            .bold()
                        
                        Text("Спросите меня о чем-нибудь. Вы можете прикреплять фотографии и файлы с помощью кнопки «+» внизу.")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    // Список сообщений чата
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 16) {
                                ForEach(session.messages) { message in
                                    MessageBubble(message: message)
                                        .id(message.id)
                                }
                                
                                // Показываем индикатор загрузки только пока не начали получать потоковый ответ (пока баббл модели пуст)
                                if viewModel.isLoading && (session.messages.last?.role == .user || session.messages.last?.content.isEmpty == true) {
                                    HStack {
                                        ProgressView()
                                            .padding(.trailing, 8)
                                        Text("Gemini думает...")
                                            .font(.footnote)
                                            .foregroundColor(.secondary)
                                        Spacer()
                                    }
                                    .padding()
                                    .background(Color(.systemGray6))
                                    .cornerRadius(14)
                                    .padding(.horizontal)
                                    .id("loadingIndicator")
                                }
                                
                                if let error = viewModel.errorMessage {
                                    VStack(alignment: .leading, spacing: 12) {
                                        HStack {
                                            Image(systemName: "exclamationmark.triangle.fill")
                                                .foregroundColor(.red)
                                            Text("Ошибка отправки")
                                                .font(.system(size: 16, weight: .semibold))
                                                .foregroundColor(.red)
                                            Spacer()

                                            Button(action: {
                                                Task {
                                                    await viewModel.retryLastMessage()
                                                }
                                            }) {
                                                HStack(spacing: 4) {
                                                    Image(systemName: "arrow.clockwise")
                                                    Text("Повторить")
                                                }
                                                .font(.system(size: 13, weight: .bold))
                                                .foregroundColor(.white)
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 6)
                                                .background(Color.red)
                                                .cornerRadius(8)
                                            }
                                        }
                                        Text(error)
                                            .font(.footnote)
                                            .foregroundColor(.secondary)
                                    }
                                    .padding()
                                    .background(Color.red.opacity(0.08))
                                    .cornerRadius(14)
                                    .padding(.horizontal)
                                    .id("errorIndicator")
                                }
                            }
                            .padding(.vertical)
                        }
                        .background(
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    hideKeyboard()
                                }
                        )
                        .simultaneousGesture(
                            DragGesture().onChanged { value in
                                // Если пользователь тянет палец вниз более чем на 15 поинтов, убираем клавиатуру
                                if value.translation.height > 15 {
                                    hideKeyboard()
                                }
                            }
                        )
                        .onChange(of: session.messages) { _ in
                            scrollToBottom(proxy: proxy, session: session)
                        }
                        .onChange(of: viewModel.isLoading) { _ in
                            scrollToBottom(proxy: proxy, session: session)
                        }
                        .onAppear {
                            scrollToBottom(proxy: proxy, session: session)
                        }
                    }
                }
            } else {
                Text("Пожалуйста, создайте новый чат")
                    .foregroundColor(.secondary)
                    .frame(maxHeight: .infinity)
            }
            
            Divider()
            
            
            // Панель предпросмотра прикрепленных файлов (над вводом текста)
            if !pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(pendingAttachments) { item in
                            ZStack(alignment: .topTrailing) {
                                HStack(spacing: 8) {
                                    if let img = item.image {
                                        Image(uiImage: img)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 44, height: 44)
                                            .cornerRadius(8)
                                            .clipped()
                                    } else {
                                        ZStack {
                                            Color.blue.opacity(0.1)
                                            Image(systemName: "doc.fill")
                                                .foregroundColor(.blue)
                                                .font(.system(size: 16))
                                        }
                                        .frame(width: 44, height: 44)
                                        .cornerRadius(8)
                                    }
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.fileName)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundColor(.primary)
                                            .lineLimit(1)
                                            .frame(maxWidth: 100)
                                        
                                        Text(item.mimeType.components(separatedBy: "/").last?.uppercased() ?? "FILE")
                                            .font(.system(size: 8))
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(.vertical, 6)
                                .padding(.horizontal, 10)
                                .background(Color(.systemGray6))
                                .cornerRadius(12)
                                
                                // Кнопка удаления вложения
                                Button(action: {
                                    pendingAttachments.removeAll(where: { $0.id == item.id })
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.gray)
                                        .background(Color.white.clipShape(Circle()))
                                        .font(.system(size: 16))
                                        .offset(x: 4, y: -4)
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                }
            }
            
            // Панель ввода сообщений
            HStack(spacing: 12) {
                // Кнопка добавления файлов и фото
                Menu {
                    Button(action: { showImagePicker = true }) {
                        Label("Медиатека / Фото", systemImage: "photo.on.rectangle")
                    }
                    Button(action: { showDocumentPicker = true }) {
                        Label("Выбрать файл / Документ", systemImage: "doc.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 26))
                        .foregroundColor(.blue)
                }
                
                TextField("Спросите Gemini...", text: $inputText)
                    .textFieldStyle(PlainTextFieldStyle())
                    .padding(14)
                    .background(Color(.systemGray6))
                    .cornerRadius(22)
                    .disableAutocorrection(true)
                
                Button(action: sendMessageAction) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .padding(12)
                        .background((inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingAttachments.isEmpty) ? Color.gray.opacity(0.5) : Color.blue)
                        .clipShape(Circle())
                }
                .disabled((inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingAttachments.isEmpty) || viewModel.isLoading)
            }
            .padding()
            .background(Color(.systemBackground))
        }
        // Листы вызова Pickers
        .sheet(isPresented: $showImagePicker) {
            ImagePicker { image, data, fileName in
                let pending = PendingAttachment(fileName: fileName, mimeType: "image/jpeg", data: data, image: image)
                pendingAttachments.append(pending)
            }
        }
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPicker { url, data, fileName in
                let mime = getMimeType(for: url)
                let isImage = mime.hasPrefix("image/")
                let uiImage = isImage ? UIImage(data: data) : nil
                let pending = PendingAttachment(fileName: fileName, mimeType: mime, data: data, image: uiImage)
                pendingAttachments.append(pending)
            }
        }
    }
    
    /// Определение MIME типа по расширению файла
    private func getMimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
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
        let textToSend = inputText
        inputText = ""
        
        // Переносим вложения во внутреннюю директорию
        var savedAttachments: [ChatAttachment] = []
        for pending in pendingAttachments {
            if let uniqueName = viewModel.saveFileToDisk(data: pending.data, fileName: pending.fileName) {
                let attachment = ChatAttachment(fileName: uniqueName, mimeType: pending.mimeType, fileURLString: uniqueName)
                savedAttachments.append(attachment)
            }
        }
        
        // Очищаем стейт временных вложений
        pendingAttachments = []
        
        Task {
            await viewModel.sendMessage(text: textToSend, attachments: savedAttachments)
        }
    }
    
    private func scrollToBottom(proxy: ScrollViewProxy, session: ChatSession) {
        // Проверяем, идет ли прямо сейчас активный посимвольный вывод текста
        let isActivelyStreaming = viewModel.isTyping && session.messages.last?.role == .model && !(session.messages.last?.content.isEmpty ?? true)
        
        if isActivelyStreaming {
            // Без анимации во время активного стриминга символов для идеального прилипания и устранения дерганий скролла
            if let lastMessage = session.messages.last {
                proxy.scrollTo(lastMessage.id, anchor: .bottom)
            }
        } else {
            // С плавной анимацией для остальных случаев (отправка сообщения, загрузка, новые чаты)
            withAnimation(.easeOut(duration: 0.25)) {
                if viewModel.errorMessage != nil {
                    proxy.scrollTo("errorIndicator", anchor: .bottom)
                } else if viewModel.isLoading && (session.messages.last?.role == .user || session.messages.last?.content.isEmpty == true) {
                    proxy.scrollTo("loadingIndicator", anchor: .bottom)
                } else if let lastMessage = session.messages.last {
                    proxy.scrollTo(lastMessage.id, anchor: .bottom)
                }
            }
        }
    }
}


// MARK: - Пузырьки сообщений (Поддержка Markdown)

struct MessageBubble: View {
    let message: ChatMessage
    @State private var isCopied: Bool = false // Стейт для визуального эффекта копирования
    
    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 50)
                
                VStack(alignment: .trailing, spacing: 8) {
                    // Рендеринг отправленных пользователем вложений
                    if let attachments = message.attachments, !attachments.isEmpty {
                        ForEach(attachments) { attachment in
                            AttachmentBubbleView(attachment: attachment)
                        }
                    }
                    
                    if !message.content.isEmpty {
                        // Для сообщений пользователя используем белый цвет текста Markdown
                        MarkdownView(text: message.content, textColor: .white)
                            .padding(14)
                            .background(Color.blue)
                            .cornerRadius(18, corners: [.topLeft, .topRight, .bottomLeft])
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    // Рендеринг вложений со стороны Gemini
                    if let attachments = message.attachments, !attachments.isEmpty {
                        ForEach(attachments) { attachment in
                            AttachmentBubbleView(attachment: attachment)
                        }
                    }
                    
                    if !message.content.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            // Рендеринг текста Gemini с поддержкой Markdown
                            MarkdownView(text: message.content, textColor: .primary)
                            
                            HStack {
                                // Кнопка копирования сообщения целиком
                                Button(action: {
                                    UIPasteboard.general.string = message.content
                                    withAnimation {
                                        isCopied = true
                                    }
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                        withAnimation {
                                            isCopied = false
                                        }
                                    }
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                                        Text(isCopied ? "Скопировано" : "Копировать")
                                    }
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(isCopied ? .green : .secondary)
                                }
                                
                                Spacer()
                                
                                Text(message.timestamp, style: .time)
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.top, 4)
                        }
                        .padding(14)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(18, corners: [.topLeft, .topRight, .bottomRight])
                    }
                }
                
                Spacer(minLength: 50)
            }
        }
        .padding(.horizontal)
    }
}

// MARK: - Компонент отображения отдельного вложения в чате

struct AttachmentBubbleView: View {
    let attachment: ChatAttachment
    
    var body: some View {
        Group {
            if attachment.mimeType.hasPrefix("image/"),
               let url = attachment.localURL,
               let data = try? Data(contentsOf: url),
               let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: 220, maxHeight: 180)
                    .cornerRadius(12)
                    .clipped()
            } else {
                // Карточка отображения файла
                HStack(spacing: 8) {
                    ZStack {
                        Color.blue.opacity(0.1)
                        Image(systemName: "doc.fill")
                            .foregroundColor(.blue)
                            .font(.system(size: 16))
                    }
                    .frame(width: 36, height: 36)
                    .cornerRadius(8)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        // Очищаем UUID префикс при отображении названия файла пользователю
                        Text(attachment.fileName.components(separatedBy: "_").dropFirst().joined(separator: "_"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .frame(maxWidth: 160)
                        
                        Text(attachment.mimeType.uppercased())
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(8)
                .background(Color(.systemGray5))
                .cornerRadius(10)
            }
        }
    }
}


// MARK: - Вспомогательные расширения

extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
    
    func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(roundedRect: rect, byRoundingCorners: corners, cornerRadii: CGSize(width: radius, height: radius))
        return Path(path.cgPath)
    }
}
