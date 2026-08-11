// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation
import PDFKit
import SharedDomain
import FindlePersistence

/// Read-only data access for the MCP catalog tools. Wraps the shared Findle
/// database (opened read-only) and renders results as JSON text for agents.
///
/// Phase 1 ("catalog"): exact, structural queries over the existing `courses`
/// and `items` tables. No text extraction or embeddings yet — those arrive in
/// later milestones.
struct Catalog {
    let database: Database
    /// Writable full-text index + extracted-text cache (the server's own DB).
    /// Optional: the catalog tools work without it; only text search/caching do.
    let indexStore: IndexStore?
    /// On-device embedder for semantic search. Optional like `indexStore`.
    let embedder: Embedder?

    /// The site the user is signed into. Derived from the first account so the
    /// server keeps working if Findle finishes signing in after launch.
    var siteID: String? {
        (try? database.fetchAccounts())?.first?.siteID
    }

    // MARK: - Tools

    func listCourses() -> String {
        guard let siteID else { return Self.noAccountJSON }
        do {
            let courses = try database.fetchCourses(siteID: siteID)
            let tagsByCourse = (try? database.fetchAllCourseTags(siteID: siteID)) ?? [:]
            let cursors = (try? database.fetchAllSyncCursors(siteID: siteID)) ?? []
            let cursorByCourse = Dictionary(uniqueKeysWithValues: cursors.map { ($0.courseID, $0) })
            let fileCounts = Dictionary(
                grouping: try database.fetchAllItems(siteID: siteID).filter { !$0.isDirectory },
                by: \.courseID
            ).mapValues(\.count)

            let out = courses.map { course -> CourseOut in
                let cursor = cursorByCourse[course.id]
                return CourseOut(
                    id: course.id,
                    fullName: course.fullName,
                    shortName: course.shortName,
                    folderName: course.effectiveFolderName,
                    syncEnabled: course.isSyncEnabled,
                    tags: (tagsByCourse[course.id] ?? []).map(\.name),
                    fileCount: fileCounts[course.id] ?? 0,
                    lastSynced: cursor.map { $0.lastSyncDate.ISO8601Format() }
                )
            }
            return Self.encode(out)
        } catch {
            return Self.errorJSON(error)
        }
    }

    /// Return the small amount of context an agent usually needs before it
    /// asks for a specific document. The limits are deliberate: course
    /// orientation should not require loading an entire Finder tree into the
    /// model context.
    func getCourseBrief(courseID: Int, maxSections: Int, maxFilesPerSection: Int, maxChars: Int) -> String {
        guard let siteID else { return Self.noAccountJSON }
        do {
            guard let course = try database.fetchCourses(siteID: siteID).first(where: { $0.id == courseID }) else {
                return Self.errorJSON(message: "No course with id \(courseID)")
            }

            let items = try database.fetchItems(courseID: courseID, siteID: siteID)
            guard let root = items.first(where: { $0.parentID == nil }) else {
                return Self.errorJSON(message: "No synced contents for course \(courseID). It may not be sync-enabled.")
            }

            let childrenByParent = Dictionary(grouping: items, by: { $0.parentID })
            // Older shared databases predate the outline table. The Finder
            // projection remains useful even before the next sync backfills it.
            let persistedOutline = try? database.fetchCourseOutline(courseID: courseID, siteID: siteID)
            let outlineBySectionID = Dictionary(
                uniqueKeysWithValues: (persistedOutline?.sections ?? [])
                    .map { ($0.id, $0) }
            )
            let sectionLimit = max(1, min(maxSections, 50))
            let fileLimit = max(1, min(maxFilesPerSection, 25))
            let summaryLimit = max(200, min(maxChars, 8_000))
            let upcomingCutoff = Date().addingTimeInterval(-86_400)
            let sections = (childrenByParent[root.id] ?? [])
                .filter(\.isDirectory)
                .sorted(by: Self.itemOrder)

            var truncated = sections.count > sectionLimit
            let sectionOut = sections.prefix(sectionLimit).map { section in
                let descendants = Self.descendants(of: section.id, childrenByParent: childrenByParent)
                let files = descendants
                    .filter { !$0.isDirectory }
                    .sorted(by: Self.itemOrder)
                truncated = truncated || files.count > fileLimit
                let activities = (outlineBySectionID[section.remoteID]?.modules ?? [])
                    .filter(\.visible)
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                truncated = truncated || activities.count > 20
                return BriefSection(
                    id: section.id,
                    name: section.filename,
                    summary: outlineBySectionID[section.remoteID].flatMap { Self.compactText($0.summary ?? "", maxCharacters: 600) },
                    fileCount: files.count,
                    files: files.prefix(fileLimit).map(BriefFile.init),
                    activities: activities.prefix(20).map(BriefActivity.init)
                )
            }

            let assignments = try database.fetchAssignments(siteID: siteID)
                .filter { $0.courseID == courseID && ($0.dueDate ?? .distantPast) >= upcomingCutoff }
                .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
                .prefix(5)
                .map {
                    BriefDeadline(
                        type: "assignment",
                        id: $0.id,
                        name: $0.name,
                        due: $0.dueDate?.ISO8601Format() ?? "",
                        submitted: $0.submitted
                    )
                }

            let quizzes = try database.fetchQuizzes(siteID: siteID)
                .filter { $0.courseID == courseID && ($0.closeDate ?? .distantPast) >= upcomingCutoff }
                .sorted { ($0.closeDate ?? .distantFuture) < ($1.closeDate ?? .distantFuture) }
                .prefix(5)
                .map {
                    BriefDeadline(
                        type: "quiz",
                        id: $0.id,
                        name: $0.name,
                        due: $0.closeDate?.ISO8601Format() ?? "",
                        submitted: nil
                    )
                }

            let deadlines = (Array(assignments) + Array(quizzes))
                .sorted { $0.due < $1.due }
                .prefix(5)

            let cursor = try database.fetchSyncCursor(courseID: courseID, siteID: siteID)
            let fileCount = items.filter { !$0.isDirectory }.count
            let downloadedCount = items.filter { !$0.isDirectory && $0.syncState == .materialized }.count
            return Self.encode(CourseBriefOut(
                course: BriefCourse(
                    id: course.id,
                    name: course.fullName,
                    shortName: course.shortName,
                    summary: Self.compactText(course.summary ?? "", maxCharacters: summaryLimit),
                    visible: course.visible,
                    syncEnabled: course.isSyncEnabled,
                    lastSynced: cursor?.lastSyncDate.ISO8601Format(),
                    fileCount: fileCount,
                    downloadedCount: downloadedCount
                ),
                sections: Array(sectionOut),
                upcomingDeadlines: Array(deadlines),
                truncated: truncated
            ))
        } catch {
            return Self.errorJSON(error)
        }
    }

    func getCourseContents(courseID: Int) -> String {
        guard let siteID else { return Self.noAccountJSON }
        do {
            let items = try database.fetchItems(courseID: courseID, siteID: siteID)
            guard let root = items.first(where: { $0.parentID == nil }) else {
                return Self.errorJSON(message: "No synced contents for course \(courseID). It may not be sync-enabled.")
            }

            let childrenByParent = Dictionary(grouping: items, by: { $0.parentID })

            func build(_ item: LocalItem) -> TreeNode {
                if item.isDirectory {
                    let kids = (childrenByParent[item.id] ?? [])
                        .sorted(by: Self.itemOrder)
                        .map(build)
                    return TreeNode(id: item.id, name: item.filename, type: "folder", size: nil, downloaded: nil, children: kids)
                }
                return TreeNode(
                    id: item.id,
                    name: item.filename,
                    type: "file",
                    size: item.fileSize,
                    downloaded: item.syncState == .materialized,
                    children: nil
                )
            }

            let tree = (childrenByParent[root.id] ?? [])
                .sorted(by: Self.itemOrder)
                .map(build)
            return Self.encode(CourseContentsOut(courseID: courseID, course: root.filename, contents: tree))
        } catch {
            return Self.errorJSON(error)
        }
    }

    func getItem(id: String) -> String {
        do {
            guard let item = try database.fetchItem(id: id) else {
                return Self.errorJSON(message: "No item with id \(id)")
            }
            return Self.encode(ItemOut(item))
        } catch {
            return Self.errorJSON(error)
        }
    }

    func searchItems(query: String, courseID: Int?, limit: Int) -> String {
        guard let siteID else { return Self.noAccountJSON }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Self.errorJSON(message: "Empty query") }
        do {
            let items = try database.fetchAllItems(siteID: siteID)
            let matches = items.lazy
                // Folders are included: Moodle section/activity names like
                // "Exámenes Anteriores" are exactly what a user searches for.
                // The `isDirectory` field lets the agent tell them apart.
                .filter { courseID == nil || $0.courseID == courseID }
                // Case- and diacritic-insensitive so "examen" matches
                // "Exámenes" — Moodle coursework is often accented Spanish.
                .filter {
                    $0.filename.range(
                        of: trimmed,
                        options: [.caseInsensitive, .diacriticInsensitive]
                    ) != nil
                }
                .prefix(max(1, limit))
                .map(ItemOut.init)
            return Self.encode(Array(matches))
        } catch {
            return Self.errorJSON(error)
        }
    }

    func readItem(id: String, maxChars: Int, offset: Int) -> String {
        do {
            guard let item = try database.fetchItem(id: id) else {
                return Self.errorJSON(message: "No item with id \(id)")
            }
            if item.isDirectory {
                return Self.errorJSON(message: "Item \(id) is a folder, not a readable file")
            }

            switch fullText(for: item) {
            case .failure(let message):
                return Self.errorJSON(message: message)
            case .success(let full):
                let characters = Array(full)
                let cap = max(256, min(maxChars, 20_000))
                let start = max(0, min(offset, characters.count))
                let end = min(characters.count, start + cap)
                let truncated = end < characters.count
                let text = String(characters[start..<end])
                return Self.encode(ReadItemOut(
                    id: id,
                    filename: item.filename,
                    courseID: item.courseID,
                    characters: full.count,
                    offset: start,
                    nextOffset: truncated ? end : nil,
                    truncated: truncated,
                    text: text,
                    path: itemPath(for: item)
                ))
            }
        } catch {
            return Self.errorJSON(error)
        }
    }

    func searchText(query: String, courseID: Int?, limit: Int) -> String {
        guard let indexStore else {
            return Self.errorJSON(message: "Full-text index unavailable.")
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Self.errorJSON(message: "Empty query") }

        let hits = indexStore.search(query: trimmed, courseID: courseID, limit: limit)
        let out = hits.map {
            SearchHit(
                id: $0.itemID,
                courseID: $0.courseID,
                filename: $0.filename,
                snippet: $0.snippet,
                contentVersion: $0.contentVersion,
                path: pathForItemID($0.itemID)
            )
        }
        // An empty result over a sparse index is ambiguous, so hint at indexing.
        if out.isEmpty {
            return Self.encode(SearchTextResult(matches: [], note: "No matches. Only files already read (or indexed via index_course) are searchable."))
        }
        return Self.encode(SearchTextResult(matches: out, note: nil))
    }

    /// Concept search over embedded chunks. Returns the most semantically similar
    /// passages, ranked by cosine similarity. Requires index_course to have run.
    func semanticSearch(query: String, courseID: Int?, k: Int) -> String {
        guard let indexStore, let embedder else {
            return Self.errorJSON(message: "Semantic search unavailable.")
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Self.errorJSON(message: "Empty query") }

        let language = Embedder.detectLanguage(trimmed)
        guard let embedded = embedder.embed(trimmed, language: language) else {
            return Self.errorJSON(message: "Could not embed the query.")
        }

        let candidates = indexStore.fetchEmbeddings(language: embedded.language.rawValue, courseID: courseID)
        if candidates.isEmpty {
            return Self.encode(SemanticResult(matches: [], note: "Nothing embedded for this language yet. Run index_course on the relevant course first."))
        }

        let ranked = candidates
            .map { (hit: $0, score: Embedder.cosineSimilarity(embedded.vector, $0.vector)) }
            .sorted { $0.score > $1.score }
            .prefix(max(1, k))
            .map { scored in
                SemanticHit(
                    id: scored.hit.itemID,
                    courseID: scored.hit.courseID,
                    filename: scored.hit.filename,
                    score: (scored.score * 1000).rounded() / 1000,
                    passage: String(scored.hit.chunkText.prefix(400)),
                    contentVersion: scored.hit.contentVersion,
                    path: pathForItemID(scored.hit.itemID)
                )
            }
        return Self.encode(SemanticResult(matches: ranked, note: nil))
    }

    /// Chunk, embed, and store `text` for `item` — built during index_course so
    /// the embedding index mirrors the full-text index.
    private func embedAndStore(item: LocalItem, text: String) {
        guard let indexStore, let embedder, !text.isEmpty else { return }
        let version = item.contentVersion ?? ""
        guard !indexStore.hasEmbeddings(itemID: item.id, contentVersion: version) else { return }

        let language = Embedder.detectLanguage(text)
        let chunks = Embedder.chunks(of: text).enumerated().compactMap { index, chunkText -> IndexStore.EmbeddingChunk? in
            guard let embedded = embedder.embed(chunkText, language: language) else { return nil }
            return IndexStore.EmbeddingChunk(index: index, text: chunkText, language: embedded.language.rawValue, vector: embedded.vector)
        }
        guard !chunks.isEmpty else { return }
        indexStore.replaceEmbeddings(itemID: item.id, courseID: item.courseID, filename: item.filename, contentVersion: version, chunks: chunks)
    }

    func indexCourse(courseID: Int) -> String {
        guard let siteID else { return Self.noAccountJSON }
        guard indexStore != nil else { return Self.errorJSON(message: "Full-text index unavailable.") }
        do {
            let files = try database.fetchItems(courseID: courseID, siteID: siteID).filter { !$0.isDirectory }
            var indexed = 0
            var skipped = 0
            var characters = 0
            for file in files {
                switch fullText(for: file) {
                case .success(let text):
                    embedAndStore(item: file, text: text)
                    indexed += 1
                    characters += text.count
                case .failure:
                    skipped += 1
                }
            }
            return Self.encode([
                "courseID": courseID,
                "filesIndexed": indexed,
                "filesSkipped": skipped,
                "totalCharacters": characters
            ])
        } catch {
            return Self.errorJSON(error)
        }
    }

    private enum TextResult {
        case success(String)
        case failure(String)
    }

    /// Full extracted text for `item`: served from the cache when present at the
    /// current content version, otherwise materialized (File Provider download),
    /// extracted, and cached. Returns a user-facing message on failure.
    private func fullText(for item: LocalItem) -> TextResult {
        let version = item.contentVersion ?? ""
        if let cached = indexStore?.cachedText(itemID: item.id, contentVersion: version) {
            return .success(cached)
        }

        guard let fileURL = (try? resolveFileURL(for: item)) ?? nil else {
            return .failure("Could not locate the File Provider folder for this item.")
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .failure("File not on disk at \(fileURL.path)")
        }
        // Reading the file triggers File Provider materialization if it isn't
        // local yet — the extension holds the token.
        let text: String
        switch Self.extractText(from: fileURL, filename: item.filename) {
        case .unsupported:
            let ext = (item.filename as NSString).pathExtension.lowercased()
            return .failure("Text extraction is not supported for .\(ext) files yet.")
        case .unreadable:
            // Don't cache a read failure as empty text — surface it so the agent
            // can retry once the File Provider finishes downloading the file.
            return .failure("Could not read \(item.filename) — it may still be downloading. Try again.")
        case .text(let extracted):
            text = extracted
        }

        indexStore?.upsert(
            itemID: item.id,
            courseID: item.courseID,
            filename: item.filename,
            content: text,
            contentVersion: version
        )
        return .success(text)
    }

    /// Ask the Findle app to pull fresh content by opening a `findle://sync`
    /// URL. The app (which holds the Moodle token) performs the sync; this MCP
    /// process never syncs directly. Best-effort and fire-and-forget — the agent
    /// should re-query after a few seconds.
    func triggerSync(courseID: Int?) -> String {
        var urlString = "findle://sync"
        if let courseID { urlString += "?course=\(courseID)" }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // -g: hand the URL to the app without bringing it to the foreground.
        process.arguments = ["-g", urlString]
        do {
            try process.run()
            return Self.encode(TriggerSyncOut(
                requested: true,
                scope: courseID.map { "course \($0)" } ?? "all enabled courses",
                note: "Asked Findle to sync. New content appears once the app finishes — re-query (list_courses / get_course_contents / read_item) in a few seconds. Findle must be installed and signed in."
            ))
        } catch {
            return Self.errorJSON(error)
        }
    }

    func getMoodleURL(id: String) -> String {
        do {
            guard let item = try database.fetchItem(id: id) else {
                return Self.errorJSON(message: "No item with id \(id)")
            }
            guard let url = item.remoteURL?.absoluteString else {
                return Self.errorJSON(message: "Item \(id) has no Moodle URL")
            }
            return Self.encode(["id": id, "moodleURL": url])
        } catch {
            return Self.errorJSON(error)
        }
    }

    // MARK: - Tracking tools

    func listDeadlines(courseID: Int?, withinDays: Int?) -> String {
        guard let siteID else { return Self.noAccountJSON }
        do {
            let assignments = try database.fetchAssignments(siteID: siteID)
            let quizzes = try database.fetchQuizzes(siteID: siteID)

            var dated: [(due: Date, out: DeadlineOut)] = []
            for a in assignments where courseID == nil || a.courseID == courseID {
                guard let due = a.dueDate else { continue }
                dated.append((due, DeadlineOut(type: "assignment", id: a.id, courseID: a.courseID, name: a.name, due: due.ISO8601Format(), submitted: a.submitted, graded: a.graded)))
            }
            for q in quizzes where courseID == nil || q.courseID == courseID {
                guard let close = q.closeDate else { continue }
                dated.append((close, DeadlineOut(type: "quiz", id: q.id, courseID: q.courseID, name: q.name, due: close.ISO8601Format(), submitted: nil, graded: nil)))
            }

            // Keep upcoming (with a day of grace), optionally within a window.
            let now = Date()
            dated = dated.filter { $0.due >= now.addingTimeInterval(-86_400) }
            if let withinDays {
                let latest = now.addingTimeInterval(TimeInterval(withinDays) * 86_400)
                dated = dated.filter { $0.due <= latest }
            }
            return Self.encode(dated.sorted { $0.due < $1.due }.map(\.out))
        } catch {
            return Self.errorJSON(error)
        }
    }

    func getSubmissionStatus(assignmentID: Int) -> String {
        guard let siteID else { return Self.noAccountJSON }
        do {
            let assignments = try database.fetchAssignments(siteID: siteID)
            guard let a = assignments.first(where: { $0.id == assignmentID }) else {
                return Self.errorJSON(message: "No assignment with id \(assignmentID)")
            }
            return Self.encode(SubmissionOut(
                assignmentID: a.id,
                courseID: a.courseID,
                name: a.name,
                dueDate: a.dueDate?.ISO8601Format(),
                submitted: a.submitted,
                graded: a.graded,
                grade: a.grade
            ))
        } catch {
            return Self.errorJSON(error)
        }
    }

    func getGrades(courseID: Int?) -> String {
        guard let siteID else { return Self.noAccountJSON }
        do {
            var items = try database.fetchGradeItems(siteID: siteID)
            if let courseID { items = items.filter { $0.courseID == courseID } }
            return Self.encode(items.map {
                GradeOut(courseID: $0.courseID, item: $0.itemName, grade: $0.grade, percentage: $0.percentage, feedback: $0.feedback)
            })
        } catch {
            return Self.errorJSON(error)
        }
    }

    func getQuizAttempts(quizID: Int) -> String {
        guard let siteID else { return Self.noAccountJSON }
        do {
            let attempts = try database.fetchQuizAttempts(siteID: siteID).filter { $0.quizID == quizID }
            let quizName = try database.fetchQuizzes(siteID: siteID).first(where: { $0.id == quizID })?.name
            return Self.encode(QuizAttemptsOut(
                quizID: quizID,
                quiz: quizName,
                attempts: attempts
                    .sorted { $0.attemptNumber < $1.attemptNumber }
                    .map {
                        AttemptOut(
                            attempt: $0.attemptNumber,
                            state: $0.state,
                            score: $0.sumGrades,
                            started: $0.startTime?.ISO8601Format(),
                            finished: $0.finishTime?.ISO8601Format()
                        )
                    }
            ))
        } catch {
            return Self.errorJSON(error)
        }
    }

    // MARK: - File resolution & extraction

    /// Reconstruct the on-disk File Provider path for `item` by walking the item
    /// tree to the course root, then descending the actual filesystem and
    /// matching each name flexibly. Stored names can drift from disk (e.g. an
    /// older course folder lacks the "[CODE]" suffix the DB now stores), so each
    /// component is matched exact → case/diacritic-insensitive → prefix.
    private func resolveFileURL(for item: LocalItem) throws -> URL? {
        guard let root = Self.cloudStorageRoot() else { return nil }

        var names: [String] = []
        var current: LocalItem? = item
        var hops = 0
        while let node = current, hops < 64 {
            names.insert(node.filename, at: 0)
            guard let parentID = node.parentID else { break }
            current = try database.fetchItem(id: parentID)
            hops += 1
        }

        var url = root
        for name in names {
            guard let match = Self.bestChildMatch(in: url, name: name) else { return nil }
            url = match
        }
        return url
    }

    private static func cloudStorageRoot() -> URL? {
        let base = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/CloudStorage", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
        return entries.first { $0.lastPathComponent.hasPrefix("Findle") }
    }

    private func itemPath(for item: LocalItem) -> String {
        var names: [String] = []
        var current: LocalItem? = item
        var hops = 0
        while let node = current, hops < 64 {
            names.insert(node.filename, at: 0)
            current = node.parentID.flatMap { try? database.fetchItem(id: $0) }
            hops += 1
        }
        return names.joined(separator: "/")
    }

    private func pathForItemID(_ itemID: String) -> String? {
        guard let item = try? database.fetchItem(id: itemID) else { return nil }
        return itemPath(for: item)
    }

    static func bestChildMatch(in directory: URL, name: String) -> URL? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return nil
        }
        if let exact = entries.first(where: { $0.lastPathComponent == name }) {
            return exact
        }
        func fold(_ s: String) -> String {
            s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }
        let target = fold(name)
        if let insensitive = entries.first(where: { fold($0.lastPathComponent) == target }) {
            return insensitive
        }
        // The on-disk name commonly drifts to a SHORTER form than the DB record
        // ("Campos Electromagnéticos" on disk vs "… [DIE-GITT-221]" stored), so
        // prefer the longest on-disk name that is a prefix of the target — the
        // most specific match. This disambiguates siblings like "Cálculo" vs
        // "Cálculo II" (a plain "first prefix" would pick either arbitrarily).
        if let best = entries
            .filter({ target.hasPrefix(fold($0.lastPathComponent)) })
            .max(by: { fold($0.lastPathComponent).count < fold($1.lastPathComponent).count }) {
            return best
        }
        // Rare reverse drift (on-disk name longer than stored): closest/shortest.
        return entries
            .filter { fold($0.lastPathComponent).hasPrefix(target) }
            .min(by: { fold($0.lastPathComponent).count < fold($1.lastPathComponent).count })
    }

    /// The outcome of extracting text from a file.
    enum Extraction {
        /// Extracted text — possibly empty (e.g. a scanned PDF with no text layer).
        case text(String)
        /// The file type isn't extractable yet.
        case unsupported
        /// The file couldn't be opened/read (e.g. still materializing, or I/O error).
        case unreadable
    }

    /// Extract full plain text from a file, distinguishing a genuinely empty
    /// document from a read failure (so failures aren't cached as empty text).
    static func extractText(from url: URL, filename: String) -> Extraction {
        let ext = (filename as NSString).pathExtension.lowercased()
        let raw: String

        switch ext {
        case "pdf":
            // A nil document means the file couldn't be parsed (e.g. partial
            // download); a non-nil doc with no text is a legitimately empty PDF.
            guard let document = PDFDocument(url: url) else { return .unreadable }
            raw = document.string ?? ""
        case "txt", "md", "markdown", "csv", "tsv", "json", "tex", "log", "srt", "rtf",
             "swift", "py", "c", "cpp", "h", "java", "js", "ts":
            guard let s = (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else { return .unreadable }
            raw = s
        case "html", "htm":
            guard let s = (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else { return .unreadable }
            raw = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        default:
            return .unsupported
        }

        return .text(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Output types

    private struct CourseBriefOut: Codable {
        let course: BriefCourse
        let sections: [BriefSection]
        let upcomingDeadlines: [BriefDeadline]
        let truncated: Bool
    }

    private struct BriefCourse: Codable {
        let id: Int
        let name: String
        let shortName: String
        let summary: String
        let visible: Bool
        let syncEnabled: Bool
        let lastSynced: String?
        let fileCount: Int
        let downloadedCount: Int
    }

    private struct BriefSection: Codable {
        let id: String
        let name: String
        let summary: String?
        let fileCount: Int
        let files: [BriefFile]
        let activities: [BriefActivity]
    }

    private struct BriefActivity: Codable {
        let id: Int
        let name: String
        let type: String
        let fileCount: Int

        init(_ module: CourseOutlineModule) {
            id = module.id
            name = module.name
            type = module.type
            fileCount = module.files.count
        }
    }

    private struct BriefFile: Codable {
        let id: String
        let name: String
        let size: Int64
        let downloaded: Bool

        init(_ item: LocalItem) {
            id = item.id
            name = item.filename
            size = item.fileSize
            downloaded = item.syncState == .materialized
        }
    }

    private struct BriefDeadline: Codable {
        let type: String
        let id: Int
        let name: String
        let due: String
        let submitted: Bool?
    }

    private struct CourseOut: Codable {
        let id: Int
        let fullName: String
        let shortName: String
        let folderName: String
        let syncEnabled: Bool
        let tags: [String]
        let fileCount: Int
        let lastSynced: String?
    }

    private struct DeadlineOut: Codable {
        let type: String
        let id: Int
        let courseID: Int
        let name: String
        let due: String
        let submitted: Bool?
        let graded: Bool?
    }

    private struct SubmissionOut: Codable {
        let assignmentID: Int
        let courseID: Int
        let name: String
        let dueDate: String?
        let submitted: Bool
        let graded: Bool
        let grade: String?
    }

    private struct GradeOut: Codable {
        let courseID: Int
        let item: String
        let grade: String?
        let percentage: String?
        let feedback: String?
    }

    private struct QuizAttemptsOut: Codable {
        let quizID: Int
        let quiz: String?
        let attempts: [AttemptOut]
    }

    private struct AttemptOut: Codable {
        let attempt: Int
        let state: String
        let score: Double?
        let started: String?
        let finished: String?
    }

    private struct SearchTextResult: Codable {
        let matches: [SearchHit]
        let note: String?
    }

    private struct TriggerSyncOut: Codable {
        let requested: Bool
        let scope: String
        let note: String
    }

    private struct SemanticResult: Codable {
        let matches: [SemanticHit]
        let note: String?
    }

    private struct SemanticHit: Codable {
        let id: String
        let courseID: Int
        let filename: String
        let score: Float
        let passage: String
        let contentVersion: String?
        let path: String?
    }

    private struct SearchHit: Codable {
        let id: String
        let courseID: Int
        let filename: String
        let snippet: String
        let contentVersion: String?
        let path: String?
    }

    private struct CourseContentsOut: Codable {
        let courseID: Int
        let course: String
        let contents: [TreeNode]
    }

    private struct TreeNode: Codable {
        let id: String
        let name: String
        let type: String
        let size: Int64?
        let downloaded: Bool?
        let children: [TreeNode]?
    }

    private struct ReadItemOut: Codable {
        let id: String
        let filename: String
        let courseID: Int
        let characters: Int
        let offset: Int
        let nextOffset: Int?
        let truncated: Bool
        let text: String
        let path: String
    }

    private struct ItemOut: Codable {
        let id: String
        let filename: String
        let courseID: Int
        let isDirectory: Bool
        let fileSize: Int64
        let syncState: String
        let downloaded: Bool
        let moodleURL: String?

        init(_ item: LocalItem) {
            id = item.id
            filename = item.filename
            courseID = item.courseID
            isDirectory = item.isDirectory
            fileSize = item.fileSize
            syncState = item.syncState.rawValue
            downloaded = item.syncState == .materialized
            moodleURL = item.remoteURL?.absoluteString
        }
    }

    /// Folders first, then alphabetical — matches how the app's UI lists contents.
    private static func itemOrder(_ a: LocalItem, _ b: LocalItem) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        return a.filename.localizedCaseInsensitiveCompare(b.filename) == .orderedAscending
    }

    private static func descendants(
        of parentID: String,
        childrenByParent: [String?: [LocalItem]]
    ) -> [LocalItem] {
        var result: [LocalItem] = []
        var frontier = childrenByParent[parentID] ?? []
        while !frontier.isEmpty {
            result.append(contentsOf: frontier)
            frontier = frontier.flatMap { childrenByParent[$0.id] ?? [] }
        }
        return result
    }

    private static func compactText(_ text: String, maxCharacters: Int) -> String {
        let withoutTags = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let compact = withoutTags
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return String(compact.prefix(maxCharacters))
    }

    // MARK: - Encoding helpers

    private static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        // MCP responses are model input. Compact JSON avoids spending context
        // on indentation while keeping deterministic key ordering for tests.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }
            ?? #"{"error":"Failed to encode response"}"#
    }

    private static func errorJSON(_ error: Error) -> String {
        errorJSON(message: error.localizedDescription)
    }

    private static func errorJSON(message: String) -> String {
        encode(["error": message])
    }

    private static let noAccountJSON =
        #"{"error":"No account signed in. Open Findle and sign in first."}"#
}

/// Transport-neutral argument accessor, so the stdio and HTTP front-ends share
/// one tool dispatch regardless of how they decode arguments.
struct ArgReader {
    let string: (String) -> String?
    let int: (String) -> Int?
}

extension Catalog {
    static func toolResult(_ text: String) -> (text: String, isError: Bool) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            return (text, false)
        }
        return (text, object["error"] != nil)
    }

    static func missingArgument(_ name: String) -> (text: String, isError: Bool) {
        (Self.errorJSON(message: "Missing required argument: \(name)"), true)
    }

    /// Run a tool by name. Shared by both transports; returns the JSON text and
    /// whether it represents an error.
    func callTool(named name: String, args: ArgReader) -> (text: String, isError: Bool) {
        switch name {
        case "list_courses":
            return Self.toolResult(listCourses())
        case "get_course_brief":
            guard let course = args.int("course") else { return Self.missingArgument("course") }
            return Self.toolResult(getCourseBrief(
                courseID: course,
                maxSections: args.int("max_sections") ?? 12,
                maxFilesPerSection: args.int("max_files_per_section") ?? 8,
                maxChars: args.int("max_chars") ?? 2_000
            ))
        case "get_course_contents":
            guard let course = args.int("course") else { return Self.missingArgument("course") }
            return Self.toolResult(getCourseContents(courseID: course))
        case "search_items":
            guard let query = args.string("query") else { return Self.missingArgument("query") }
            return Self.toolResult(searchItems(query: query, courseID: args.int("course"), limit: args.int("limit") ?? 20))
        case "search_text":
            guard let query = args.string("query") else { return Self.missingArgument("query") }
            return Self.toolResult(searchText(query: query, courseID: args.int("course"), limit: args.int("limit") ?? 10))
        case "semantic_search":
            guard let query = args.string("query") else { return Self.missingArgument("query") }
            return Self.toolResult(semanticSearch(query: query, courseID: args.int("course"), k: args.int("k") ?? 6))
        case "index_course":
            guard let course = args.int("course") else { return Self.missingArgument("course") }
            return Self.toolResult(indexCourse(courseID: course))
        case "read_item":
            guard let id = args.string("id") else { return Self.missingArgument("id") }
            return Self.toolResult(readItem(id: id, maxChars: args.int("max_chars") ?? 8_000, offset: args.int("offset") ?? 0))
        case "get_item":
            guard let id = args.string("id") else { return Self.missingArgument("id") }
            return Self.toolResult(getItem(id: id))
        case "get_moodle_url":
            guard let id = args.string("id") else { return Self.missingArgument("id") }
            return Self.toolResult(getMoodleURL(id: id))
        case "trigger_sync":
            return Self.toolResult(triggerSync(courseID: args.int("course")))
        case "list_deadlines":
            return Self.toolResult(listDeadlines(courseID: args.int("course"), withinDays: args.int("within_days")))
        case "get_submission_status":
            guard let assignmentID = args.int("assignment_id") else { return Self.missingArgument("assignment_id") }
            return Self.toolResult(getSubmissionStatus(assignmentID: assignmentID))
        case "get_grades":
            return Self.toolResult(getGrades(courseID: args.int("course")))
        case "get_quiz_attempts":
            guard let quizID = args.int("quiz_id") else { return Self.missingArgument("quiz_id") }
            return Self.toolResult(getQuizAttempts(quizID: quizID))
        default:
            return ("Unknown tool: \(name)", true)
        }
    }
}
