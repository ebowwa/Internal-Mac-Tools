//
//  ContentView.swift
//  Internal Tools
//
//  Created by Elijah Arbee on 10/17/24.
//
// TODO:
/**
 - add code ide like running alongside the read&write (mid)
 - store all chats and system prompts and responses (mid)
 - add a refresh to the state of the chat (high)
 - add live suggestions to the interface when the user is coding cells (low priority)
 - cells selected should be chunked together and embedded with highest similarity given to model to augment memory/understanding in code writting and understanding over large contexts
 */

import SwiftUI
import Combine

// ====== MARK: - Data Model ======

struct CodeCell: Codable, Identifiable {
    let id: UUID
    var language: String
    var code: String
    var needs: [String]
    var groupID: UUID?
    var userInput: String? // New property added

    init(id: UUID = UUID(), language: String = "Unknown", code: String = "", needs: [String] = [], groupID: UUID? = nil, userInput: String? = nil) {
        self.id = id
        self.language = language
        self.code = code
        self.needs = needs
        self.groupID = groupID
        self.userInput = userInput
    }
}

// ====== MARK: - Chat Message Model ======

struct ChatMessage: Codable {
    var role: String
    var content: String
}

// ====== MARK: - LLM Response Model ======

struct LLMResponse: Codable {
    let id: String
    let object: String
    let created: Int
    let choices: [Choice]
    let usage: Usage?

    struct Choice: Codable {
        let index: Int
        let message: ChatMessage
        let finish_reason: String?
    }

    struct Usage: Codable {
        let prompt_tokens: Int
        let completion_tokens: Int
        let total_tokens: Int
    }
}

// ====== MARK: - Data Manager Singleton ======

class DataManager: ObservableObject {
    static let shared = DataManager()
    @Published var codeCells: [CodeCell] = []
    private let fileName = "code_cells.json"

    private init() {
        loadCells()
    }

    // Get the file URL in the app's Documents directory
    private func getFileURL() -> URL? {
        let fm = FileManager.default
        do {
            let docs = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            return docs.appendingPathComponent(fileName)
        } catch {
            print("Error getting file URL: \(error)")
            return nil
        }
    }

    // Load cells from JSON file
    func loadCells() {
        guard let url = getFileURL(),
              let data = try? Data(contentsOf: url) else {
            // If no file exists, initialize with an empty array
            self.codeCells = []
            return
        }
        do {
            let decoder = JSONDecoder()
            self.codeCells = try decoder.decode([CodeCell].self, from: data)
        } catch {
            print("Error decoding JSON: \(error)")
            self.codeCells = []
        }
    }

    // Save cells to JSON file
    func saveCells() {
        guard let url = getFileURL() else { return }
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(codeCells)
            try data.write(to: url)
        } catch {
            print("Error encoding/saving JSON: \(error)")
        }
    }

    // Add a new code cell
    func addCell(_ cell: CodeCell) {
        codeCells.append(cell)
        saveCells()
    }

    // Update an existing cell
    func updateCell(_ cell: CodeCell) {
        if let index = codeCells.firstIndex(where: { $0.id == cell.id }) {
            codeCells[index] = cell
            saveCells()
        }
    }

    // Delete cells
    func deleteCells(at offsets: IndexSet) {
        codeCells.remove(atOffsets: offsets)
        saveCells()
    }
}

// ====== MARK: - LLM Client Delegate ======

class LLMClientDelegate: NSObject, URLSessionDataDelegate {
    var onReceiveResponse: ((String) -> Void)?
    var onCompletion: ((LLMResponse) -> Void)?

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if let onReceiveResponse = onReceiveResponse {
            if let dataString = String(data: data, encoding: .utf8) {
                let lines = dataString.components(separatedBy: "\n")
                for line in lines {
                    if line.starts(with: "data: ") {
                        let jsonString = String(line.dropFirst(6))
                        if jsonString == "[DONE]" {
                            // Stream finished
                            return
                        } else if let jsonData = jsonString.data(using: .utf8) {
                            do {
                                let decoder = JSONDecoder()
                                let chunk = try decoder.decode(StreamingChunk.self, from: jsonData)
                                if let content = chunk.choices.first?.delta.content {
                                    DispatchQueue.main.async {
                                        onReceiveResponse(content)
                                    }
                                }
                            } catch {
                                print("Error decoding streaming chunk: \(error)")
                            }
                        }
                    }
                }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Handle errors if needed
        if let error = error {
            print("URLSession Task Error: \(error.localizedDescription)")
        }
    }

    struct StreamingChunk: Codable {
        let choices: [Choice]

        struct Choice: Codable {
            let delta: Delta
            let index: Int
            let finish_reason: String?
        }

        struct Delta: Codable {
            let role: String?
            let content: String?
        }
    }
}

// ====== MARK: - LLM Client Singleton ======

class LLMClient: ObservableObject {
    static let shared = LLMClient()

    // API-related variables
    @Published var apiURL: String = "http://localhost:11434/v1/chat/completions"
    @Published var model: String = "llama3.2:1b"
    @Published var stream: Bool = true
    @Published var apiKey: String? = nil // OpenAI API key (if needed)

    private var session: URLSession!
    private var delegate: LLMClientDelegate!

    private init() {
        delegate = LLMClientDelegate()
        let configuration = URLSessionConfiguration.default
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    // Send a request to the LLM API with streaming support
    func sendRequest(messages: [ChatMessage], onReceive: @escaping (String) -> Void, onCompletion: @escaping (LLMResponse) -> Void) {
        guard let url = URL(string: apiURL) else {
            print("Invalid API URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        // Add the API key to the header if it exists
        if let apiKey = apiKey {
            request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        // Payload
        let payload: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "stream": stream
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        } catch {
            print("Error encoding JSON: \(error)")
            return
        }

        // Assign callbacks
        delegate.onReceiveResponse = { content in
            DispatchQueue.main.async {
                onReceive(content)
            }
        }

        delegate.onCompletion = { response in
            DispatchQueue.main.async {
                onCompletion(response)
            }
        }

        // Start the data task
        let task = session.dataTask(with: request)
        task.resume()
    }
}

// ====== MARK: - ContentView ======

struct ContentView: View {
    @ObservedObject var dataManager = DataManager.shared
    @ObservedObject var llmClient = LLMClient.shared
    @State private var selectedCellIDs: Set<UUID> = []
    @State private var showingSettings = false
    @State private var showingNewCellSheet = false

    var body: some View {
        NavigationView {
            VStack {
                // Inside ContentView
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach($dataManager.codeCells) { $cell in
                            CodeCellView(
                                cell: $cell,
                                isSelected: selectedCellIDs.contains(cell.id),
                                onDelete: { deleteCell(cell) } // Pass delete action here
                            )
                            .onTapGesture {
                                toggleSelection(for: cell.id)
                            }
                            .onAppear {
                                dataManager.loadCells()  // Ensure cells are reloaded when the view appears
                            }

                        }
                        .padding(.horizontal)
                    }
                }


                Divider()
                    .padding(.vertical, 5)

                // MagicTextBox for LLM interactions
                MagicTextBox(selectedCellIDs: $selectedCellIDs)
                    .padding([.horizontal, .bottom])
            }
            .navigationBarTitle("Code Notebook", displayMode: .inline)
            .navigationBarItems(
                leading: Button(action: { showingSettings = true }) {
                    Image(systemName: "gear")
                        .imageScale(.large)
                },
                trailing: Button(action: { showingNewCellSheet = true }) {
                    Image(systemName: "plus")
                        .imageScale(.large)
                }
            )
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showingNewCellSheet) {
                NewCellView()
            }
        }
        // Add this line to set the navigation view style
        .navigationViewStyle(StackNavigationViewStyle())
    }

    // Toggle selection of a code cell
    private func toggleSelection(for id: UUID) {
        if selectedCellIDs.contains(id) {
            selectedCellIDs.remove(id)
        } else {
            selectedCellIDs.insert(id)
        }
    }

    // Delete function
    private func delete(at offsets: IndexSet) {
        dataManager.deleteCells(at: offsets)
    }
    // Helper function to delete a specific cell
    private func deleteCell(_ cell: CodeCell) {
        if let index = dataManager.codeCells.firstIndex(where: { $0.id == cell.id }) {
            dataManager.codeCells.remove(at: index)
            dataManager.saveCells() // Save the updated list to persist the changes
        }
    }

}

// ====== MARK: - CodeCellView ======

struct CodeCellView: View {
    @Binding var cell: CodeCell
    var isSelected: Bool
    var onDelete: () -> Void // Add a delete action closure
    @State private var isEditing = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header with language and needs
            HStack {
                Text("Language: \(cell.language)")
                    .font(.headline)
                Spacer()
                Text(cell.needs.joined(separator: ", "))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            // Display user input if available
            if let userInput = cell.userInput {
                Text("User Input:")
                    .font(.headline)
                Text(userInput)
                    .font(.body)
                    .padding(5)
                    .background(Color(UIColor.systemGray5))
                    .cornerRadius(8)
            }
            
            // Code Editor or Display
            if isEditing {
                TextEditor(text: $cell.code)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 100)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.5)))
            } else {
                ScrollView {
                    if let attributedString = try? AttributedString(markdown: cell.code) {
                        Text(attributedString)
                            .textSelection(.enabled)
                    } else {
                        Text(cell.code)
                            .textSelection(.enabled)
                    }
                }
                .padding(5)
                .background(Color(UIColor.systemGray6))
                .cornerRadius(8)
            }
            
            // Action Buttons (Edit/Done and Delete)
            HStack {
                // "Edit" / "Done" Button
                Button(action: { isEditing.toggle() }) {
                    Text(isEditing ? "Done" : "Edit")
                        .padding(6)
                        .frame(maxWidth: .infinity)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(5)
                }
                
                Spacer()
                
                // "Delete" Button
                Button(action: onDelete) {
                    Text("Delete")
                        .padding(6)
                        .frame(maxWidth: .infinity)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(5)
                }
            }

            // "Run" Button (separate from other action buttons)
            Button(action: { /* Implement actions like Run, Compile, etc. */ }) {
                Text("Run")
                    .padding(6)
                    .frame(maxWidth: .infinity)
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(5)
            }
        }
        .padding()
        .background(isSelected ? Color.blue.opacity(0.1) : Color(UIColor.secondarySystemBackground))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
        )
        .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
    }
}

// ====== MARK: - MagicTextBox ======

struct MagicTextBox: View {
    @Binding var selectedCellIDs: Set<UUID>
    @State private var objectInput: String = ""
    @State private var questionInput: String = ""
    @State private var showSuggestion: Bool = false
    @State private var suggestedPrompt: String = ""
    @State private var isProcessing: Bool = false
    @State private var responseText: String = ""
    @State private var showingAlert: Bool = false
    @State private var alertMessage: String = ""
    @State private var savedQuestionInput: String = "" // New state variable
    // Additional state to hold usage metrics
    @State private var usage: LLMResponse.Usage?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Conditionally show the object input field if no cells are selected
            if selectedCellIDs.isEmpty {
                TextField("Enter the object in question...", text: $objectInput)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .disableAutocorrection(true)
                    .autocapitalization(.none)
            }

            // Question Input Field
            TextField("Ask the LLM about your code...", text: $questionInput)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .disableAutocorrection(true)
                .autocapitalization(.none)
                .onChange(of: questionInput) { newValue in
                    suggestedPrompt = suggestPrompt(for: newValue)
                    showSuggestion = !suggestedPrompt.isEmpty
                }

            // Suggestion Text
            if showSuggestion {
                Text("Suggestion: \(suggestedPrompt)")
                    .foregroundColor(.gray)
                    .onTapGesture {
                        questionInput = suggestedPrompt
                        showSuggestion = false
                    }
            }

            // Submit Button
            Button(action: performMagic) {
                HStack {
                    Spacer()
                    Text(isProcessing ? "Processing..." : "Submit to LLM")
                        .foregroundColor(.white)
                        .padding()
                    Spacer()
                }
                .background(isProcessing ? Color.gray : Color.blue)
                .cornerRadius(8)
            }
            .disabled(isProcessing)

            // LLM Response Display
            if !responseText.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("User Input:")
                        .font(.headline)
                    Text(savedQuestionInput)
                        .font(.body)
                        .padding(5)
                        .background(Color(UIColor.systemGray5))
                        .cornerRadius(8)

                    Text("LLM Response:")
                        .font(.headline)
                        .padding(.top, 10)
                    ScrollView {
                        if let attributedString = try? AttributedString(markdown: responseText) {
                            Text(attributedString)
                                .textSelection(.enabled)
                        } else {
                            Text(responseText)
                                .textSelection(.enabled)
                        }
                    }
                    .padding()
                    .background(Color(UIColor.systemGray6))
                    .cornerRadius(8)
                    .frame(maxHeight: UIScreen.main.bounds.height * 0.3)
                    
                    // "Copy" Button for the LLM response
                    Button(action: {
                        UIPasteboard.general.string = responseText
                    }) {
                        Text("Copy Response")
                            .padding(6)
                            .frame(maxWidth: .infinity)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(5)
                    }
                }
                .padding()
                .background(Color(UIColor.systemBackground))
                .cornerRadius(10)
                .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: -2)
            }

            // Usage Display
            if let usage = usage {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Usage Metrics:")
                        .font(.headline)
                    Text("Prompt Tokens: \(usage.prompt_tokens)")
                    Text("Completion Tokens: \(usage.completion_tokens)")
                    Text("Total Tokens: \(usage.total_tokens)")
                }
                .font(.subheadline)
                .padding()
                .background(Color(UIColor.systemGray5))
                .cornerRadius(8)
            }
        }
        .padding()
        .background(Color(UIColor.systemBackground))
        .cornerRadius(10)
        .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: -2)
        .alert(isPresented: $showingAlert) {
            Alert(title: Text("Notice"), message: Text(alertMessage), dismissButton: .default(Text("OK")))
        }
    }

    // Suggest improved prompt
    func suggestPrompt(for input: String) -> String {
        // Placeholder for a more sophisticated suggestion mechanism
        if input.lowercased().contains("write this in a more") {
            return "Please specify the target language and desired improvements clearly."
        }
        return ""
    }

    // Perform the magic action
    func performMagic() {
        guard !questionInput.isEmpty else {
            alertMessage = "Please enter your question or instruction."
            showingAlert = true
            return
        }

        isProcessing = true
        responseText = ""
        usage = nil
        savedQuestionInput = questionInput // Save before resetting

        var messages: [ChatMessage] = []

        // System prompt
        messages.append(ChatMessage(role: "system", content: "You are a helpful assistant that assists with code and programming tasks."))

        if selectedCellIDs.isEmpty {
            guard !objectInput.isEmpty else {
                alertMessage = "Please enter the object in question or select a code cell."
                showingAlert = true
                isProcessing = false
                return
            }
            // Construct message with objectInput
            let content = """
            Object:
            \(objectInput)

            Question:
            \(savedQuestionInput)
            """
            messages.append(ChatMessage(role: "user", content: content))
        } else {
            // Combine selected cells' code
            let selectedCells = DataManager.shared.codeCells.filter { selectedCellIDs.contains($0.id) }
            let combinedCode = selectedCells.map { $0.code }.joined(separator: "\n\n")

            // Construct message with selected cells' code
            let content = """
            Question:
            \(savedQuestionInput)

            Code:
            \(combinedCode)
            """
            messages.append(ChatMessage(role: "user", content: content))
        }

        // Send the messages to the LLM
        LLMClient.shared.sendRequest(messages: messages, onReceive: { content in
            responseText += content
        }, onCompletion: { finalResponse in
            isProcessing = false
            // Append the response as a new code cell
            let newCell = CodeCell(language: "LLM Response", code: responseText, userInput: savedQuestionInput)
            DataManager.shared.addCell(newCell)

            // Store usage metrics
            usage = finalResponse.usage
        })

        // Reset inputs
        questionInput = ""
        if selectedCellIDs.isEmpty {
            objectInput = ""
        }
        suggestedPrompt = ""
        showSuggestion = false
    }
}

// ====== MARK: - SettingsView ======

struct SettingsView: View {
    @ObservedObject var llmClient = LLMClient.shared
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("LLM Configuration")) {
                    TextField("API URL", text: $llmClient.apiURL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                    TextField("Model", text: $llmClient.model)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Toggle("Stream Responses", isOn: $llmClient.stream)
                }
            }
            .navigationBarTitle("Settings", displayMode: .inline)
            .navigationBarItems(trailing: Button("Done") {
                DataManager.shared.saveCells()
                presentationMode.wrappedValue.dismiss()
            })
        }
    }
}

// ====== MARK: - NewCellView ======

struct NewCellView: View {
    @Environment(\.presentationMode) var presentationMode
    @State private var newCellLanguage: String = ""
    @State private var newCellNeeds: String = ""
    @State private var newCellCode: String = ""
    @State private var showingAlert: Bool = false
    @State private var alertMessage: String = ""

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("New Code Cell")) {
                    TextField("Language (e.g., Swift, Python)", text: $newCellLanguage)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField("Needs (comma separated)", text: $newCellNeeds)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextEditor(text: $newCellCode)
                        .frame(height: 150)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.5)))
                }
            }
            .navigationBarTitle("Add New Cell", displayMode: .inline)
            .navigationBarItems(leading: Button("Cancel") {
                presentationMode.wrappedValue.dismiss()
            }, trailing: Button("Add") {
                addNewCell()
            })
            .alert(isPresented: $showingAlert) {
                Alert(title: Text("Error"), message: Text(alertMessage), dismissButton: .default(Text("OK")))
            }
        }
    }

    func addNewCell() {
        guard !newCellLanguage.isEmpty else {
            alertMessage = "Please enter a language."
            showingAlert = true
            return
        }

        let needsArray = newCellNeeds.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let newCell = CodeCell(language: newCellLanguage, code: newCellCode, needs: needsArray)
        DataManager.shared.addCell(newCell)
        presentationMode.wrappedValue.dismiss()
    }
}

// ====== MARK: - Preview ======

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
