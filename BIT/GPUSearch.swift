import Metal
import MetalKit
import Foundation

// MARK: - GPU搜索引擎主类
class GPUSearchEngine: ObservableObject {
    // Metal设备和资源
    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var library: MTLLibrary?
    
    // 计算管道
    private var stringMatchPipeline: MTLComputePipelineState?
    private var fuzzySearchPipeline: MTLComputePipelineState?
    private var scoringPipeline: MTLComputePipelineState?
    private var sortingPipeline: MTLComputePipelineState?
    
    // GPU缓冲区
    private var appDataBuffer: MTLBuffer?
    private var queryBuffer: MTLBuffer?
    private var resultBuffer: MTLBuffer?
    private var scoreBuffer: MTLBuffer?
    
    // 搜索配置
    private let maxApps = 2000
    private let maxStringLength = 256
    private let cpuThreshold = 50  // 少于50个应用时使用CPU
    
    // 性能监控
    @Published var isGPUSearchAvailable: Bool = false
    @Published var lastSearchTime: TimeInterval = 0
    @Published var searchedAppCount: Int = 0
    @Published var gpuUtilization: Float = 0.0
    
    // 搜索缓存
    private var searchCache: [String: [AppItem]] = [:]
    private let cacheQueue = DispatchQueue(label: "search.cache", attributes: .concurrent)
    private let maxCacheSize = 100
    
    init() {
        initializeGPUSearch()
    }
    
    // MARK: - 初始化
    
    func initialize() {
        initializeGPUSearch()
        setupComputePipelines()
        createSearchBuffers()
        preloadSearchData()
    }
    
    private func initializeGPUSearch() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("⚠️ GPU search unavailable: Metal not supported")
            isGPUSearchAvailable = false
            return
        }
        
        self.device = device
        self.commandQueue = device.makeCommandQueue()
        
        // 加载着色器库
        if let path = Bundle.main.path(forResource: "Shaders", ofType: "metallib"),
           let library = try? device.makeLibrary(filepath: path) {
            self.library = library
        } else {
            self.library = device.makeDefaultLibrary()
        }
        
        isGPUSearchAvailable = true
        
        #if DEBUG
        print("🔍 GPU Search Engine initialized")
        print("🔍 Max threads per threadgroup: \(device.maxThreadsPerThreadgroup)")
        print("🔍 Supports concurrent compute: \(device.supportsFamily(.apple7))")
        #endif
    }
    
    private func setupComputePipelines() {
        guard let device = device, let library = library else { return }
        
        setupStringMatchPipeline(device: device, library: library)
        setupFuzzySearchPipeline(device: device, library: library)
        setupScoringPipeline(device: device, library: library)
        setupSortingPipeline(device: device, library: library)
    }
    
    private func setupStringMatchPipeline(device: MTLDevice, library: MTLLibrary) {
        guard let function = library.makeFunction(name: "string_match_compute") else {
            print("⚠️ string_match_compute function not found")
            return
        }
        
        do {
            stringMatchPipeline = try device.makeComputePipelineState(function: function)
        } catch {
            print("❌ Failed to create string match pipeline: \(error)")
        }
    }
    
    private func setupFuzzySearchPipeline(device: MTLDevice, library: MTLLibrary) {
        guard let function = library.makeFunction(name: "fuzzy_search_compute") else {
            print("⚠️ fuzzy_search_compute function not found")
            return
        }
        
        do {
            fuzzySearchPipeline = try device.makeComputePipelineState(function: function)
        } catch {
            print("❌ Failed to create fuzzy search pipeline: \(error)")
        }
    }
    
    private func setupScoringPipeline(device: MTLDevice, library: MTLLibrary) {
        guard let function = library.makeFunction(name: "search_scoring_compute") else {
            print("⚠️ search_scoring_compute function not found")
            return
        }
        
        do {
            scoringPipeline = try device.makeComputePipelineState(function: function)
        } catch {
            print("❌ Failed to create scoring pipeline: \(error)")
        }
    }
    
    private func setupSortingPipeline(device: MTLDevice, library: MTLLibrary) {
        guard let function = library.makeFunction(name: "parallel_sort_compute") else {
            print("⚠️ parallel_sort_compute function not found")
            return
        }
        
        do {
            sortingPipeline = try device.makeComputePipelineState(function: function)
        } catch {
            print("❌ Failed to create sorting pipeline: \(error)")
        }
    }
    
    private func createSearchBuffers() {
        guard let device = device else { return }
        
        // 应用数据缓冲区
        let appDataSize = maxApps * MemoryLayout<GPUAppData>.size
        appDataBuffer = device.makeBuffer(length: appDataSize, options: [.storageModeShared])
        appDataBuffer?.label = "App Data Buffer"
        
        // 查询缓冲区
        let querySize = maxStringLength * MemoryLayout<CChar>.size
        queryBuffer = device.makeBuffer(length: querySize, options: [.storageModeShared])
        queryBuffer?.label = "Query Buffer"
        
        // 结果缓冲区
        let resultSize = maxApps * MemoryLayout<SearchResult>.size
        resultBuffer = device.makeBuffer(length: resultSize, options: [.storageModeShared])
        resultBuffer?.label = "Result Buffer"
        
        // 评分缓冲区
        let scoreSize = maxApps * MemoryLayout<Float>.size
        scoreBuffer = device.makeBuffer(length: scoreSize, options: [.storageModeShared])
        scoreBuffer?.label = "Score Buffer"
        
        #if DEBUG
        print("🔍 Search buffers created: \((appDataSize + querySize + resultSize + scoreSize) / 1024)KB")
        #endif
    }
    
    private func preloadSearchData() {
        // 预加载常用搜索模式数据
    }
    
    // MARK: - 主要搜索接口
    
    func searchApps(_ apps: [AppItem], query: String) -> [AppItem] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        // 空查询返回全部
        if trimmedQuery.isEmpty {
            return apps
        }
        
        // 检查缓存
        if let cachedResults = getCachedResults(for: trimmedQuery) {
            return cachedResults
        }
        
        let startTime = CACurrentMediaTime()
        let results: [AppItem]
        
        // 根据数据量选择搜索策略
        if apps.count < cpuThreshold || !isGPUSearchAvailable {
            results = performCPUSearch(apps, query: trimmedQuery)
        } else {
            results = performGPUSearch(apps, query: trimmedQuery)
        }
        
        let searchTime = CACurrentMediaTime() - startTime
        updateSearchMetrics(searchTime: searchTime, appCount: apps.count, usedGPU: apps.count >= cpuThreshold)
        
        // 缓存结果
        cacheSearchResults(query: trimmedQuery, results: results)
        
        return results
    }
    
    // MARK: - GPU搜索实现
    
    private func performGPUSearch(_ apps: [AppItem], query: String) -> [AppItem] {
        guard let device = device,
              let commandQueue = commandQueue,
              let pipeline = stringMatchPipeline,
              let scoringPipeline = scoringPipeline else {
            return performCPUSearch(apps, query: query)
        }
        
        // 准备GPU数据
        guard let appData = prepareAppDataForGPU(apps),
              let queryData = prepareQueryDataForGPU(query) else {
            return performCPUSearch(apps, query: query)
        }
        
        // 执行GPU搜索
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return performCPUSearch(apps, query: query)
        }
        
        commandBuffer.label = "GPU Search Command Buffer"
        
        // 第一阶段：字符串匹配
        if let matchEncoder = commandBuffer.makeComputeCommandEncoder() {
            executeStringMatchPhase(
                encoder: matchEncoder,
                pipeline: pipeline,
                appData: appData,
                queryData: queryData,
                appCount: apps.count
            )
            matchEncoder.endEncoding()
        }
        
        // 第二阶段：评分计算
        if let scoringEncoder = commandBuffer.makeComputeCommandEncoder() {
            executeScoringPhase(
                encoder: scoringEncoder,
                pipeline: scoringPipeline,
                appCount: apps.count
            )
            scoringEncoder.endEncoding()
        }
        
        // 提交并等待完成
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        // 读取结果
        return extractSearchResults(apps: apps)
    }
    
    private func prepareAppDataForGPU(_ apps: [AppItem]) -> MTLBuffer? {
        guard let buffer = appDataBuffer else { return nil }
        
        let pointer = buffer.contents().bindMemory(to: GPUAppData.self, capacity: maxApps)
        
        for (index, app) in apps.enumerated() {
            guard index < maxApps else { break }
            
            var gpuAppData = GPUAppData()
            
            // 复制应用名称
            let nameData = app.name.lowercased().data(using: .utf8) ?? Data()
            let nameCopy = min(nameData.count, 127) // 保留一位给null terminator
            nameData.withUnsafeBytes { bytes in
                memcpy(&gpuAppData.name, bytes.baseAddress, nameCopy)
            }
            gpuAppData.name.127 = 0 // null terminator
            
            // 复制Bundle ID
            let bundleData = app.bundleID.lowercased().data(using: .utf8) ?? Data()
            let bundleCopy = min(bundleData.count, 127)
            bundleData.withUnsafeBytes { bytes in
                memcpy(&gpuAppData.bundleID, bytes.baseAddress, bundleCopy)
            }
            gpuAppData.bundleID.127 = 0
            
            gpuAppData.index = UInt32(index)
            gpuAppData.nameLength = UInt32(nameCopy)
            gpuAppData.bundleIDLength = UInt32(bundleCopy)
            
            pointer[index] = gpuAppData
        }
        
        return buffer
    }
    
    private func prepareQueryDataForGPU(_ query: String) -> MTLBuffer? {
        guard let buffer = queryBuffer else { return nil }
        
        let queryData = query.data(using: .utf8) ?? Data()
        let copyLength = min(queryData.count, maxStringLength - 1)
        
        let pointer = buffer.contents().bindMemory(to: CChar.self, capacity: maxStringLength)
        
        queryData.withUnsafeBytes { bytes in
            memcpy(pointer, bytes.baseAddress, copyLength)
        }
        pointer[copyLength] = 0 // null terminator
        
        return buffer
    }
    
    private func executeStringMatchPhase(
        encoder: MTLComputeCommandEncoder,
        pipeline: MTLComputePipelineState,
        appData: MTLBuffer,
        queryData: MTLBuffer,
        appCount: Int
    ) {
        encoder.label = "String Match Phase"
        encoder.setComputePipelineState(pipeline)
        
        encoder.setBuffer(appData, offset: 0, index: 0)
        encoder.setBuffer(queryData, offset: 0, index: 1)
        encoder.setBuffer(resultBuffer, offset: 0, index: 2)
        
        var params = SearchParameters(
            appCount: UInt32(appCount),
            queryLength: UInt32(strlen(queryData.contents().bindMemory(to: CChar.self, capacity: 1))),
            matchThreshold: 0.3,
            fuzzyThreshold: 0.6
        )
        
        encoder.setBytes(&params, length: MemoryLayout<SearchParameters>.size, index: 3)
        
        let threadsPerGroup = MTLSize(width: min(pipeline.maxTotalThreadsPerThreadgroup, 256), height: 1, depth: 1)
        let threadGroups = MTLSize(
            width: (appCount + threadsPerGroup.width - 1) / threadsPerGroup.width,
            height: 1,
            depth: 1
        )
        
        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadsPerGroup)
    }
    
    private func executeScoringPhase(
        encoder: MTLComputeCommandEncoder,
        pipeline: MTLComputePipelineState,
        appCount: Int
    ) {
        encoder.label = "Scoring Phase"
        encoder.setComputePipelineState(pipeline)
        
        encoder.setBuffer(appDataBuffer, offset: 0, index: 0)
        encoder.setBuffer(queryBuffer, offset: 0, index: 1)
        encoder.setBuffer(resultBuffer, offset: 0, index: 2)
        encoder.setBuffer(scoreBuffer, offset: 0, index: 3)
        
        let threadsPerGroup = MTLSize(width: min(pipeline.maxTotalThreadsPerThreadgroup, 256), height: 1, depth: 1)
        let threadGroups = MTLSize(
            width: (appCount + threadsPerGroup.width - 1) / threadsPerGroup.width,
            height: 1,
            depth: 1
        )
        
        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadsPerGroup)
    }
    
    private func extractSearchResults(apps: [AppItem]) -> [AppItem] {
        guard let resultBuffer = resultBuffer,
              let scoreBuffer = scoreBuffer else {
            return []
        }
        
        let resultPointer = resultBuffer.contents().bindMemory(to: SearchResult.self, capacity: maxApps)
        let scorePointer = scoreBuffer.contents().bindMemory(to: Float.self, capacity: maxApps)
        
        var scoredResults: [(AppItem, Float)] = []
        
        for i in 0..<min(apps.count, maxApps) {
            let result = resultPointer[i]
            let score = scorePointer[i]
            
            if result.isMatch != 0 && score > 0 {
                let index = Int(result.appIndex)
                if index < apps.count {
                    scoredResults.append((apps[index], score))
                }
            }
        }
        
        // 按评分排序
        scoredResults.sort { $0.1 > $1.1 }
        
        return scoredResults.map { $0.0 }
    }
    
    // MARK: - CPU回退搜索
    
    private func performCPUSearch(_ apps: [AppItem], query: String) -> [AppItem] {
        return apps.filter { app in
            let name = app.name.lowercased()
            let bundleID = app.bundleID.lowercased()
            
            // 精确匹配优先
            if name.contains(query) || bundleID.contains(query) {
                return true
            }
            
            // 模糊匹配
            return fuzzyMatch(text: name, query: query) || fuzzyMatch(text: bundleID, query: query)
        }.sorted { app1, app2 in
            // 按匹配质量排序
            let score1 = calculateMatchScore(app: app1, query: query)
            let score2 = calculateMatchScore(app: app2, query: query)
            return score1 > score2
        }
    }
    
    private func fuzzyMatch(text: String, query: String) -> Bool {
        let textChars = Array(text)
        let queryChars = Array(query)
        
        var textIndex = 0
        var queryIndex = 0
        
        while textIndex < textChars.count && queryIndex < queryChars.count {
            if textChars[textIndex] == queryChars[queryIndex] {
                queryIndex += 1
            }
            textIndex += 1
        }
        
        return queryIndex == queryChars.count
    }
    
    private func calculateMatchScore(app: AppItem, query: String) -> Float {
        let name = app.name.lowercased()
        let bundleID = app.bundleID.lowercased()
        
        var score: Float = 0.0
        
        // 名称匹配权重更高
        if name.hasPrefix(query) {
            score += 100.0
        } else if name.contains(query) {
            score += 50.0
        } else if fuzzyMatch(text: name, query: query) {
            score += 25.0
        }
        
        // Bundle ID匹配
        if bundleID.contains(query) {
            score += 20.0
        } else if fuzzyMatch(text: bundleID, query: query) {
            score += 10.0
        }
        
        // 苹果应用优先级
        if app.bundleID.hasPrefix("com.apple.") {
            score += 5.0
        }
        
        return score
    }
    
    // MARK: - 缓存管理
    
    private func getCachedResults(for query: String) -> [AppItem]? {
        return cacheQueue.sync {
            return searchCache[query]
        }
    }
    
    private func cacheSearchResults(query: String, results: [AppItem]) {
        cacheQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            
            self.searchCache[query] = results
            
            // 限制缓存大小
            if self.searchCache.count > self.maxCacheSize {
                let oldestKeys = Array(self.searchCache.keys.prefix(self.searchCache.count - self.maxCacheSize))
                for key in oldestKeys {
                    self.searchCache.removeValue(forKey: key)
                }
            }
        }
    }
    
    func clearSearchCache() {
        cacheQueue.async(flags: .barrier) { [weak self] in
            self?.searchCache.removeAll()
        }
    }
    
    // MARK: - 性能监控
    
    private func updateSearchMetrics(searchTime: TimeInterval, appCount: Int, usedGPU: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.lastSearchTime = searchTime
            self?.searchedAppCount = appCount
            self?.gpuUtilization = usedGPU ? 1.0 : 0.0
            
            #if DEBUG
            print("🔍 Search completed: \(appCount) apps in \(String(format: "%.3f", searchTime))ms using \(usedGPU ? "GPU" : "CPU")")
            #endif
        }
    }
    
    // MARK: - 清理
    
    func cleanup() {
        clearSearchCache()
        
        appDataBuffer = nil
        queryBuffer = nil
        resultBuffer = nil
        scoreBuffer = nil
        
        #if DEBUG
        print("🧹 GPU Search Engine cleaned up")
        #endif
    }
    
    deinit {
        cleanup()
    }
}

// MARK: - GPU数据结构

struct GPUAppData {
    var name: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar) = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
    var bundleID: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar) = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
    var index: UInt32 = 0
    var nameLength: UInt32 = 0
    var bundleIDLength: UInt32 = 0
    var reserved: UInt32 = 0
}

struct SearchResult {
    var appIndex: UInt32 = 0
    var isMatch: UInt32 = 0
    var matchType: UInt32 = 0  // 0: 精确, 1: 包含, 2: 模糊
    var reserved: UInt32 = 0
}

struct SearchParameters {
    let appCount: UInt32
    let queryLength: UInt32
    let matchThreshold: Float
    let fuzzyThreshold: Float
}