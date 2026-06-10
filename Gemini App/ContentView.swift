import SwiftUI
import Combine
import UniformTypeIdentifiers


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
    let content: String
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


// MARK: - Модели для работы с Gemini API

struct GeminiRequest: Codable {
    let contents: [GeminiContent]
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
    @Published var currentSessionId: UUID?
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    
    // API-ключ сохраняется в защищенном хранилище UserDefaults
    @AppStorage("gemini_api_key") var apiKey: String = ""
    
    // Выбранная по умолчанию модель
    @AppStorage("gemini_selected_model") var selectedModel: String = "gemini-3.5-flash"
    
    private let userDefaultsKey = "gemini_chat_sessions"
    
    init() {
        loadSessions()
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
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else { return }
        if let decoded = try? JSONDecoder().decode([ChatSession].self, from: data) {
            self.sessions = decoded
        }
    }
    
    /// Сохранение сессий на устройство
    func saveSessions() {
        if let encoded = try? JSONEncoder().encode(sessions) {
            UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
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
        
        // 1. Создаем и добавляем сообщение пользователя локально (включая ссылки на вложения)
        let userMessage = ChatMessage(role: .user, content: trimmedText, timestamp: Date(), attachments: attachments)
        
        await MainActor.run {
            self.sessions[sessionIndex].messages.append(userMessage)
            // Автоматическое переименование пустого чата по первому сообщению
            if self.sessions[sessionIndex].title.hasPrefix("Новый чат") {
                let preview = trimmedText.isEmpty ? "Файл/Изображение" : String(trimmedText.prefix(25))
                self.sessions[sessionIndex].title = preview + (trimmedText.count > 25 ? "..." : "")
            }
            self.isLoading = true
            self.errorMessage = nil
            self.saveSessions()
        }
        
        // 2. Формируем историю диалога и вложения для мультимодального запроса к API
        let apiMessages = prepareApiMessages(for: sessionIndex)
        
        // 3. Выполняем сетевой запрос
        await executeApiCall(apiMessages: apiMessages, sessionIndex: sessionIndex)
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
        // Проверяем, что последнее сообщение было отправлено пользователем (именно его мы и пытаемся повторить)
        guard let lastMessage = sessions[sessionIndex].messages.last, lastMessage.role == .user else { return }
        
        await MainActor.run {
            self.isLoading = true
            self.errorMessage = nil
        }
        
        // Формируем историю диалога на основе текущих сообщений
        let apiMessages = prepareApiMessages(for: sessionIndex)
        
        // Повторно запускаем сетевой запрос
        await executeApiCall(apiMessages: apiMessages, sessionIndex: sessionIndex)
    }
    
    /// Вспомогательный метод формирования массива объектов для API Gemini
    private func prepareApiMessages(for sessionIndex: Int) -> [GeminiContent] {
        return sessions[sessionIndex].messages.map { msg -> GeminiContent in
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
    
    /// Общий метод для выполнения сетевого запроса к API Gemini
    private func executeApiCall(apiMessages: [GeminiContent], sessionIndex: Int) async {
        let requestBody = GeminiRequest(contents: apiMessages)
        
        // Используем выбранную в настройках модель Gemini
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(selectedModel):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            await MainActor.run {
                self.isLoading = false
                self.errorMessage = "Некорректный URL API"
            }
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        do {
            request.httpBody = try JSONEncoder().encode(requestBody)
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            
            if httpResponse.statusCode != 200 {
                if let errorJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errorDetails = errorJSON["error"] as? [String: Any],
                   let message = errorDetails["message"] as? String {
                    throw NSError(domain: "GeminiError", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
                }
                throw URLError(.badServerResponse)
            }
            
            let decodedResponse = try JSONDecoder().decode(GeminiResponse.self, from: data)
            
            guard let modelReply = decodedResponse.candidates?.first?.content?.parts.first?.text else {
                throw NSError(domain: "GeminiError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Пустой ответ от модели"])
            }
            
            await MainActor.run {
                let replyMessage = ChatMessage(role: .model, content: modelReply, timestamp: Date(), attachments: nil)
                self.sessions[sessionIndex].messages.append(replyMessage)
                self.isLoading = false
                self.saveSessions()
            }
            
        } catch {
            await MainActor.run {
                self.isLoading = false
                self.errorMessage = error.localizedDescription
            }
        }
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
                                            Text(lastMsg.content)
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
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("API-КЛЮЧ GEMINI")) {
                    SecureField("Введите ваш API-ключ", text: $tempKey)
                        .disableAutocorrection(true)
                        .autocapitalization(.none)
                    
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
            }
        }
    }
    
    private func saveSettings() {
        viewModel.apiKey = tempKey
        viewModel.selectedModel = tempModel
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
                                
                                if viewModel.isLoading {
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
        withAnimation {
            if viewModel.isLoading {
                proxy.scrollTo("loadingIndicator", anchor: .bottom)
            } else if viewModel.errorMessage != nil {
                proxy.scrollTo("errorIndicator", anchor: .bottom)
            } else if let lastMessage = session.messages.last {
                proxy.scrollTo(lastMessage.id, anchor: .bottom)
            }
        }
    }
}


// MARK: - Пузырьки сообщений (Поддержка Markdown)

struct MessageBubble: View {
    let message: ChatMessage
    
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
                        Text(message.content)
                            .padding(14)
                            .background(Color.blue)
                            .foregroundColor(.white)
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
                            Text(LocalizedStringKey(message.content))
                                .font(.body)
                                .foregroundColor(.primary)
                                .textSelection(.enabled)
                            
                            Text(message.timestamp, style: .time)
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
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


// MARK: - Вспомогательное расширение для скругления отдельных углов

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
