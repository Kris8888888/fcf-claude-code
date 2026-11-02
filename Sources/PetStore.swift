import Foundation
import AppKit
import Combine

// 桌面宠物「团子」：数据、作息、心情、旅行、日记。全部在本机计算，不调模型、不联网。
// 关掉时什么都不跑：没有计时器、不监听；ChatSession 那边只在 PetStore.isOn 时才通知过来。

struct PetDay: Codable {
    var tokens = 0          // 这天吃掉的 token
    var tasks = 0           // 陪你做完的事
    var pets = 0            // 被摸头
    var snacks = 0
    var trips: [String] = []
    var sick = false
    var lateNight = false
    var waits = 0           // 等你确认的次数

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        tokens = try c.decodeIfPresent(Int.self, forKey: .tokens) ?? 0
        tasks = try c.decodeIfPresent(Int.self, forKey: .tasks) ?? 0
        pets = try c.decodeIfPresent(Int.self, forKey: .pets) ?? 0
        snacks = try c.decodeIfPresent(Int.self, forKey: .snacks) ?? 0
        trips = try c.decodeIfPresent([String].self, forKey: .trips) ?? []
        sick = try c.decodeIfPresent(Bool.self, forKey: .sick) ?? false
        lateNight = try c.decodeIfPresent(Bool.self, forKey: .lateNight) ?? false
        waits = try c.decodeIfPresent(Int.self, forKey: .waits) ?? 0
    }
}

struct Postcard: Codable, Identifiable, Hashable {
    var id = UUID()
    var place: String
    var line: String
    var gift: String
    var date: Date
}

struct PetTrip: Codable {
    var place: String
    var start: Date
    var back: Date
    var tasksBefore: Int    // 出门时的累计完成数，回来时算「你在我不在时做了几件事」
}

/// 可选的角色
enum PetCharacter: String, CaseIterable, Identifiable {
    case crab, mochi
    var id: String { rawValue }
    var label: String { self == .crab ? "小螃蟹 Clawd" : "团子" }
    var defaultName: String { self == .crab ? "Clawd" : "团子" }
}

struct PetData: Codable {
    var enabled = false
    var character = PetCharacter.crab.rawValue
    var perch = true                 // 没事就趴在客户端窗口顶上
    var perchedNow = true            // 现在是趴在窗口上，还是被你拖到了桌面上
    var perchFromRight: Double?      // 趴在窗口顶边的哪个位置（离右边多远）
    var name = PetCharacter.crab.defaultName
    var adoptedAt = Date()
    var fullness = 70.0
    var mood = 72.0
    var energy = 80.0
    var affection = 0.0
    var sick = false
    var hungrySince: Date?
    var lastUpdate = Date()
    var trip: PetTrip?
    var postcards: [Postcard] = []
    var days: [String: PetDay] = [:]
    var x: Double?
    var y: Double?
    var size = 1.0
    var reactToClaude = true
    var care = true
    var wander = true
    var flags: [String: String] = [:]     // 每天只做一次的事：记日期
    var totalTasks = 0

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let def = PetData()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? def.enabled
        character = try c.decodeIfPresent(String.self, forKey: .character) ?? def.character
        perch = try c.decodeIfPresent(Bool.self, forKey: .perch) ?? true
        perchedNow = try c.decodeIfPresent(Bool.self, forKey: .perchedNow) ?? true
        perchFromRight = try c.decodeIfPresent(Double.self, forKey: .perchFromRight)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? def.name
        adoptedAt = try c.decodeIfPresent(Date.self, forKey: .adoptedAt) ?? def.adoptedAt
        fullness = try c.decodeIfPresent(Double.self, forKey: .fullness) ?? def.fullness
        mood = try c.decodeIfPresent(Double.self, forKey: .mood) ?? def.mood
        energy = try c.decodeIfPresent(Double.self, forKey: .energy) ?? def.energy
        affection = try c.decodeIfPresent(Double.self, forKey: .affection) ?? 0
        sick = try c.decodeIfPresent(Bool.self, forKey: .sick) ?? false
        hungrySince = try c.decodeIfPresent(Date.self, forKey: .hungrySince)
        lastUpdate = try c.decodeIfPresent(Date.self, forKey: .lastUpdate) ?? Date()
        trip = try c.decodeIfPresent(PetTrip.self, forKey: .trip)
        postcards = try c.decodeIfPresent([Postcard].self, forKey: .postcards) ?? []
        days = try c.decodeIfPresent([String: PetDay].self, forKey: .days) ?? [:]
        x = try c.decodeIfPresent(Double.self, forKey: .x)
        y = try c.decodeIfPresent(Double.self, forKey: .y)
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 1
        reactToClaude = try c.decodeIfPresent(Bool.self, forKey: .reactToClaude) ?? true
        care = try c.decodeIfPresent(Bool.self, forKey: .care) ?? true
        wander = try c.decodeIfPresent(Bool.self, forKey: .wander) ?? true
        flags = try c.decodeIfPresent([String: String].self, forKey: .flags) ?? [:]
        totalTasks = try c.decodeIfPresent(Int.self, forKey: .totalTasks) ?? 0
    }
}

/// 一下子的反应（摸头、戳、吃东西、庆祝…），过几秒自己结束
enum PetAct: String {
    case petted, poked, pout, eating, celebrate, oops, stretch, medicine, wave
}

/// 画面上的样子：按优先级从各种状态里选一个
enum PetPose: String, CaseIterable {
    case away, dragged, petted, poked, pout, eating, celebrate, oops, stretch, medicine, wave
    case waiting, working, sleeping, sick, hungry, idle
}

final class PetStore: ObservableObject {
    static let shared = PetStore()
    /// ChatSession 用：没开宠物时一句判断就返回
    static var isOn: Bool { shared.data.enabled }

    @Published private(set) var data: PetData
    @Published private(set) var act: PetAct?
    @Published private(set) var actStart = Date()
    @Published private(set) var bubble: String?
    @Published private(set) var anyBusy = false
    @Published private(set) var anyWaiting = false
    @Published private(set) var asleep = false
    @Published var dragging = false
    @Published var visible = true          // 窗口被挡住/在别的桌面时停动画
    @Published var showCard = false

    weak var app: AppState?

    private var tick: Timer?
    private var wakeWatch: Timer?
    private var actTimer: DispatchWorkItem?
    private var bubbleTimer: DispatchWorkItem?
    private var saveWork: DispatchWorkItem?
    private var recentPets: [Date] = []
    private var recentPokes: [Date] = []
    private var activeMinutes = 0          // 连续在电脑前的分钟数（久坐提醒）
    private var lastChatter = Date()
    private var quietUntil = Date.distantPast

    private let file: URL = {
        // 仅用于测试：DUIHUATAI_PET_DIR 换一个目录，不碰真的宠物
        let d = ProcessInfo.processInfo.environment["DUIHUATAI_PET_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("com.likang.duihuatai/pet", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("pet.json")
    }()

    private init() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        data = (try? Data(contentsOf: file)).flatMap { try? dec.decode(PetData.self, from: $0) } ?? PetData()
    }

    // MARK: 开关

    func startIfEnabled() { if data.enabled { start() } }

    func setEnabled(_ on: Bool) {
        guard on != data.enabled else { return }
        data.enabled = on
        if on {
            data.lastUpdate = Date()       // 关着的这段时间不算饿
            save()
            start()
            say("嗨，我是\(data.name)。以后就在这儿陪你啦。摸摸我的头试试？", for: 7)
            play(.wave, 2)
        } else {
            stop()
            saveNow()
        }
    }

    private func start() {
        catchUp()
        refreshClaude()
        PetWindow.shared.show()
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.minute() }
        tick?.tolerance = 10
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.dailyGreeting() }
        if ProcessInfo.processInfo.environment["DUIHUATAI_PET_SCRIPT"] != nil { runTestScript() }
        if ProcessInfo.processInfo.environment["DUIHUATAI_PET_BUSY"] != nil { anyBusy = true }   // 测 CPU 用
        if ProcessInfo.processInfo.environment["DUIHUATAI_PET_FPS"] != nil {
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                FileHandle.standardError.write("pet fps \(Double(PetCanvas.drawn) / 2) pose \(self.pose.rawValue)\n".data(using: .utf8)!)
                PetCanvas.drawn = 0
            }
        }
    }

    private func stop() {
        tick?.invalidate(); tick = nil
        wakeWatch?.invalidate(); wakeWatch = nil
        actTimer?.cancel(); bubbleTimer?.cancel()
        act = nil; bubble = nil; showCard = false
        PetWindow.shared.hide()
    }

    // MARK: 姿势

    var pose: PetPose {
        if data.trip != nil { return .away }
        if dragging { return .dragged }
        if let act { return PetPose(rawValue: act.rawValue) ?? .idle }
        if data.reactToClaude && anyWaiting { return .waiting }
        if data.reactToClaude && anyBusy { return .working }
        if asleep { return .sleeping }
        if data.sick { return .sick }
        if data.fullness < 25 { return .hungry }
        return .idle
    }

    /// 画面刷新快慢：睡着和发呆时少画几帧，省电
    var frameInterval: Double {
        switch pose {
        case .sleeping, .away: return 1.0 / 6
        case .idle, .sick, .hungry: return 1.0 / 5
        case .working, .waiting: return 1.0 / 10
        default: return 1.0 / 24
        }
    }

    var character: PetCharacter { PetCharacter(rawValue: data.character) ?? .crab }

    func setCharacter(_ c: PetCharacter) {
        guard c != character else { return }
        let old = character
        data.character = c.rawValue
        if data.name == old.defaultName { data.name = c.defaultName }
        save()
        if data.enabled { play(.wave, 2); say("换好啦，我是\(data.name)！", for: 4) }
    }

    /// 同一句话，螃蟹说的时候换几个词
    func lingo(_ s: String) -> String {
        guard character == .crab else { return s }
        return s.replacingOccurrences(of: "麻薯", with: "螃蟹").replacingOccurrences(of: "呆毛", with: "钳子")
    }

    // 趴在窗口上：被拖到桌面后，闲一会儿自己爬回去
    private var detachedAt = Date.distantPast
    func detached() { data.perchedNow = false; detachedAt = Date(); save() }
    func perched(fromRight: Double) { data.perchedNow = true; data.perchFromRight = fromRight; save() }
    func setPerch(_ on: Bool) { data.perch = on; data.perchedNow = on; save(); PetWindow.shared.relayout() }

    var level: (n: Int, title: String) {
        let a = data.affection
        let table: [(Double, String)] = [(0, "刚认识"), (30, "混熟了"), (100, "好朋友"), (250, "死党"), (500, "家人")]
        let i = table.lastIndex { a >= $0.0 } ?? 0
        return (i + 1, table[i].1)
    }

    var daysTogether: Int {
        (Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: data.adoptedAt), to: Calendar.current.startOfDay(for: Date())).day ?? 0) + 1
    }

    var statusLine: String {
        if let t = data.trip { return "在\(t.place)玩，大约 \(Self.hm(t.back)) 回来" }
        if data.sick { return "生病了，需要吃药" }
        if anyWaiting { return "Claude 在等你确认" }
        if anyBusy { return "陪 Claude 干活中" }
        if asleep { return "睡着了" }
        if data.fullness < 25 { return "饿了" }
        if data.mood > 80 { return "心情很好" }
        if data.mood < 30 { return "有点闷闷不乐" }
        return "在发呆"
    }

    // MARK: 和 Claude 联动

    /// 有对话开始/结束忙、出现/处理完确认卡片时，ChatSession 通知过来
    func refreshClaude() {
        let ss = app?.sessions ?? []
        let busy = ss.contains { $0.busy }
        let waiting = ss.contains { $0.needsAttention }
        if waiting && !anyWaiting && data.reactToClaude && data.trip == nil {
            bumpDay { $0.waits += 1 }
            say(["Claude 在等你点头哦。", "有个操作要你确认一下～", "点我一下，带你过去确认。"].randomElement()!, for: 6)
        }
        if busy != anyBusy { anyBusy = busy }
        if waiting != anyWaiting { anyWaiting = waiting }
        if busy && asleep { wake(silently: true) }
        if busy, Self.isLateNight(Date()) { bumpDay { $0.lateNight = true } }
    }

    /// 一轮回答结束：按这轮用掉的 token 吃饭
    func finishedTurn(tokens: Int, ok: Bool, error: Bool) {
        let food = max(0, tokens)
        data.totalTasks += ok ? 1 : 0
        bumpDay { d in d.tokens += food; if ok { d.tasks += 1 } }
        guard data.trip == nil else { save(); return }
        let before = data.fullness
        data.fullness = min(100, data.fullness + min(Double(food) / 4000, 12))
        data.energy = max(0, data.energy - 0.6)
        if ok { data.mood = min(100, data.mood + 1.5); data.affection += 0.2 }
        if data.fullness >= 25 { data.hungrySince = nil }
        save()
        guard data.reactToClaude else { return }
        if error {
            play(.oops, 2.5)
            if Bool.random() { say(["哎呀，出错了…别急，再试一次。", "这次没成，摸摸头，不怪你。"].randomElement()!, for: 5) }
            return
        }
        guard ok else { return }
        if food >= 1000 {
            play(.eating, 2.2)
            if before < 30 { say("终于吃上饭了！这口有 \(Self.tokenText(food)) token。", for: 5) }
            else if data.fullness >= 99 && before < 99 { say("吃撑了…今天的 token 好管饱。", for: 5) }
            else if Double.random(in: 0..<1) < 0.18 { say(["好吃！这口有 \(Self.tokenText(food)) token。", "做完啦，顺便吃了 \(Self.tokenText(food)) token。", "嗯，这顿是 \(Self.tokenText(food)) token 的味道。"].randomElement()!, for: 4.5) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.3) { [weak self] in
                if self?.act == nil, NSApp.isActive == false { self?.play(.celebrate, 2) }
            }
        } else if !NSApp.isActive {
            play(.celebrate, 2)
        }
    }

    // MARK: 互动

    func pat() {
        guard data.trip == nil else { return }
        let now = Date()
        recentPets = recentPets.filter { now.timeIntervalSince($0) < 120 } + [now]
        if asleep { wake(silently: false); return }
        if recentPets.count > 9 {
            play(.pout, 2.2)
            say(["头发要被摸秃了啦！", "好啦好啦，知道你喜欢我了。", "再摸要收费了，一次一万 token。"].randomElement()!, for: 4)
            return
        }
        play(.petted, 2.4)
        data.mood = min(100, data.mood + 6)
        if (data.days[Self.today]?.pets ?? 0) < 30 { data.affection += 1 }
        bumpDay { $0.pets += 1 }
        save()
        if data.sick { say("被摸摸好像没那么难受了。", for: 4); return }
        if recentPets.count == 1 || Double.random(in: 0..<1) < 0.3 {
            say(["嘿嘿，舒服～", "再摸一下嘛。", "你的手好暖。", "喜欢你摸我的头。", "呼噜呼噜…"].randomElement()!, for: 3.5)
        }
    }

    func poke() {
        guard data.trip == nil else { return }
        let now = Date()
        recentPokes = recentPokes.filter { now.timeIntervalSince($0) < 6 } + [now]
        if asleep { wake(silently: false); return }
        if recentPokes.count >= 4 {
            recentPokes.removeAll()
            play(.pout, 2.5)
            say(["再戳我就生气了！", "哼，不理你了。…好吧还是理你。", "戳戳戳，我是麻薯又不是按钮。"].randomElement()!, for: 4)
            return
        }
        play(.poked, 1.2)
        if Double.random(in: 0..<1) < 0.35 { say(["嘿！", "痒～", "干嘛呀。", "在呢在呢。"].randomElement()!, for: 2.5) }
    }

    var snacksLeft: Int { max(0, 3 - (data.days[Self.today]?.snacks ?? 0)) }

    func feedSnack() {
        guard data.trip == nil else { return }
        if asleep { wake(silently: true) }
        guard snacksLeft > 0 else { say("今天的零食吃完了，等你多干点活，我吃 token 就好。", for: 5); return }
        play(.eating, 2.2)
        data.fullness = min(100, data.fullness + 12)
        data.mood = min(100, data.mood + 4)
        data.affection += 0.5
        if data.fullness >= 25 { data.hungrySince = nil }
        bumpDay { $0.snacks += 1 }
        save()
        say(["谢谢！是草莓味的。", "零食最好吃了！", "嚼嚼嚼…你也来一口？", "这个比 token 甜。"].randomElement()!, for: 4)
    }

    func giveMedicine() {
        guard data.sick else { say("我没生病呀，不用吃药。", for: 3.5); return }
        if data.fullness < 20 { say("空肚子不能吃药…先给我点吃的吧。", for: 5); return }
        dismissBubble()
        play(.medicine, 2.8)
        data.sick = false
        data.hungrySince = nil
        data.mood = max(0, data.mood - 3)
        data.affection += 2
        save()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.9) { [weak self] in
            self?.say("好苦…不过感觉好多了，谢谢你照顾我。", for: 5)
        }
    }

    var canTravel: (ok: Bool, why: String) {
        if data.trip != nil { return (false, "已经在外面玩了") }
        if data.sick { return (false, "生病了，要先吃药") }
        if data.fullness < 30 { return (false, "太饿了，走不动") }
        if data.energy < 25 { return (false, "太累了，想先睡一觉") }
        return (true, "")
    }

    func goTravel(minutes: Int? = nil) {
        guard canTravel.ok else { say(canTravel.why + "。", for: 4); return }
        let recent = Set(data.postcards.suffix(8).map(\.place))
        let pick = (PetPlaces.all.filter { !recent.contains($0.place) }.randomElement() ?? PetPlaces.all.randomElement())!
        let m = minutes ?? Int.random(in: 40...120)
        showCard = false
        say("我去\(pick.place)玩一会儿，\(m) 分钟左右回来！", for: 4)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            guard let self, self.data.trip == nil else { return }
            self.act = nil
            self.data.trip = PetTrip(place: pick.place, start: Date(), back: Date().addingTimeInterval(Double(m) * 60), tasksBefore: self.data.totalTasks)
            self.data.energy = max(0, self.data.energy - 10)
            self.bumpDay { $0.trips.append(pick.place) }
            self.save()
        }
    }

    /// 旅行中点它的行李牌：提前叫回来也行
    func callBack() {
        guard data.trip != nil else { return }
        returnHome(early: true)
    }

    private func returnHome(early: Bool) {
        guard let t = data.trip else { return }
        let p = PetPlaces.all.first { $0.place == t.place } ?? PetPlaces.all[0]
        let line = lingo(p.lines.randomElement()!)
        data.trip = nil
        data.postcards.append(Postcard(place: p.place, line: line, gift: p.gift, date: Date()))
        if data.postcards.count > 200 { data.postcards.removeFirst(data.postcards.count - 200) }
        data.mood = min(100, data.mood + (early ? 10 : 20))
        data.affection += 3
        data.lastUpdate = Date()
        save()
        play(.wave, 2.5)
        let done = data.totalTasks - t.tasksBefore
        var s = early ? "好嘛，这就回来了。" : "我回来啦！"
        s += "去了\(p.place)，\(line)给你带了\(p.gift)，放在日记本里了。"
        if done > 0 { s += "我不在的时候你做完了 \(done) 件事，真厉害。" }
        say(s, for: 9)
    }

    func toggleSleep() {
        if asleep { wake(silently: false) } else { fallAsleep(byUser: true) }
    }

    func quietForAnHour() {
        quietUntil = Date().addingTimeInterval(3600)
        bubble = nil
        play(.wave, 1.5)
    }

    func rename(_ s: String) {
        let n = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n != data.name else { return }
        data.name = String(n.prefix(8))
        save()
        if data.enabled { say("好，以后我就叫\(data.name)了！", for: 4) }
    }

    func setOption(_ k: WritableKeyPath<PetData, Bool>, _ v: Bool) { data[keyPath: k] = v; save() }

    func setSize(_ v: Double) {
        data.size = v
        save()
        PetWindow.shared.relayout()
    }

    func savePosition(_ p: CGPoint) { data.x = p.x; data.y = p.y; save() }

    func resetPosition() {
        data.x = nil; data.y = nil
        data.perchFromRight = nil; data.perchedNow = data.perch
        save()
        PetWindow.shared.relayout()
    }

    func readopt() {
        let keep = (data.enabled, data.size, data.x, data.y, data.character, data.perch)
        data = PetData()
        (data.enabled, data.size, data.x, data.y, data.character, data.perch) = keep
        data.name = character.defaultName
        act = nil; asleep = false
        saveNow()
        if data.enabled { say("你好呀，我是新来的\(data.name)。请多关照！", for: 6) }
    }

    /// 等确认时点它：带你去那个对话
    func openWaiting() -> Bool {
        guard anyWaiting, let app, let s = app.sessions.first(where: { $0.needsAttention }) else { return false }
        NSApp.activate(ignoringOtherApps: true)
        app.selected = s.id
        NSApp.windows.first { $0.canBecomeMain && !($0 is NSPanel) }?.makeKeyAndOrderFront(nil)
        return true
    }

    // MARK: 说话和动作

    func say(_ s: String, for seconds: Double) {
        guard data.enabled, Date() >= quietUntil || s.hasPrefix("嗨") else { return }
        bubble = lingo(s)
        bubbleTimer?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.bubble = nil }
        bubbleTimer = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
        lastChatter = Date()
    }

    func dismissBubble() { bubble = nil; bubbleTimer?.cancel() }

    private func play(_ a: PetAct, _ seconds: Double) {
        act = a
        actStart = Date()
        actTimer?.cancel()
        let w = DispatchWorkItem { [weak self] in if self?.act == a { self?.act = nil } }
        actTimer = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    // MARK: 时间流逝

    /// 打开 App 时补上关着这段时间的变化（最多算 12 小时，不会一开机就饿死）
    private func catchUp() {
        let now = Date()
        let hours = min(12, max(0, now.timeIntervalSince(data.lastUpdate) / 3600))
        decay(hours: hours, sleeping: hours > 1)
        data.lastUpdate = now
        if let t = data.trip, t.back <= now { returnHome(early: false) }
        save()
    }

    private func decay(hours h: Double, sleeping: Bool) {
        guard h > 0 else { return }
        let away = data.trip != nil
        data.fullness = max(0, data.fullness - h * (sleeping ? 2 : (away ? 2.5 : 4)))
        data.mood = max(0, data.mood - h * (data.fullness < 25 ? 5 : (data.sick ? 4 : 2.5)) + (away ? h * 6 : 0))
        data.mood = min(100, data.mood)
        data.energy = sleeping ? min(100, data.energy + h * 15) : max(0, data.energy - h * 3)
        if data.fullness < 15 {
            if data.hungrySince == nil { data.hungrySince = Date() }
        } else if data.fullness >= 25 {
            data.hungrySince = nil
        }
        if !data.sick, data.trip == nil,
           (data.hungrySince.map { Date().timeIntervalSince($0) > 4 * 3600 } ?? false) || data.mood < 8 {
            data.sick = true
            bumpDay { $0.sick = true }
            say("我好像生病了…头有点烫。双击我，喂我吃点药吧。", for: 8)
        }
    }

    private func minute() {
        let now = Date()
        refreshClaude()      // 关掉正在忙的对话不会触发通知，这里每分钟对一次
        decay(hours: now.timeIntervalSince(data.lastUpdate) / 3600, sleeping: asleep)
        data.lastUpdate = now
        if let t = data.trip {
            if t.back <= now { returnHome(early: false) }
            save()
            return
        }
        let idle = Self.idleSeconds()
        activeMinutes = idle < 300 ? activeMinutes + 1 : 0

        // 你走开了或者夜深了：睡觉
        if !asleep, !anyBusy, act == nil, (idle > 600 || (Self.isNight(now) && idle > 120) || data.energy < 8) {
            fallAsleep(byUser: false)
        }
        // 你不在、它也闲着：偶尔自己出去玩一趟（一天最多一次）
        if data.wander, !anyBusy, !anyWaiting, idle > 1200, !Self.isNight(now), canTravel.ok,
           data.flags["autoTrip"] != Self.today, Double.random(in: 0..<1) < 0.03 {
            data.flags["autoTrip"] = Self.today
            if asleep { asleep = false; wakeWatch?.invalidate() }
            goTravel()
        }
        if data.care, !asleep { careReminders(now: now, idle: idle) }
        // 被拖到桌面上、闲了 5 分钟：爬回窗口上趴着
        if data.perch, !data.perchedNow, !dragging, act == nil, !anyWaiting, now.timeIntervalSince(detachedAt) > 300, PetWindow.shared.canPerch {
            data.perchedNow = true
            PetWindow.shared.relayout()
            if !asleep { play(.wave, 1.5) }
        }
        if !asleep, idle < 300, now.timeIntervalSince(lastChatter) > Double.random(in: 1500...3000) { chatter() }
        save()
    }

    private func fallAsleep(byUser: Bool) {
        guard !asleep, data.trip == nil else { return }
        asleep = true
        act = nil
        if byUser { say(["那我睡一会儿，有事叫我。", "晚安…"].randomElement()!, for: 3) }
        // 自己睡着的：每 2 秒看一眼你回没回来（只读一下系统的空闲时间，很省）。你哄睡的就等你叫醒
        wakeWatch?.invalidate(); wakeWatch = nil
        guard !byUser else { return }
        wakeWatch = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, self.asleep else { return }
            if Self.idleSeconds() < 3 && !Self.isNight(Date()) { self.wake(silently: false) }
        }
        wakeWatch?.tolerance = 1
    }

    private func wake(silently: Bool) {
        guard asleep else { return }
        asleep = false
        wakeWatch?.invalidate(); wakeWatch = nil
        guard !silently else { return }
        play(.stretch, 2.2)
        let h = Calendar.current.component(.hour, from: Date())
        say(h < 10 && h >= 5 ? "早呀…我睡得好香。" : (Self.isNight(Date()) ? "嗯…还没睡吗？" : ["啊，你回来啦！", "我没睡，我在闭目思考。", "伸个懒腰～"].randomElement()!), for: 4)
    }

    // MARK: 关心你

    private func once(_ key: String, _ body: () -> Void) {
        guard data.flags[key] != Self.today else { return }
        data.flags[key] = Self.today
        body()
    }

    private func careReminders(now: Date, idle: Double) {
        let c = Calendar.current.dateComponents([.hour, .minute], from: now)
        let hm = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        if (11 * 60 + 50)...(12 * 60 + 40) ~= hm, idle < 600 {
            once("lunch") { say(["到饭点啦，你也去吃饭吧，我吃 token 就行。", "中午了，先去吃饭，回来再接着干。"].randomElement()!, for: 7) }
        }
        if (18 * 60 + 30)...(19 * 60 + 30) ~= hm, idle < 600 {
            once("offwork") { say(anyBusy ? "下班时间到了，这件做完就收工吧？" : "下班时间到啦，今天辛苦了！", for: 7) }
        }
        if hm >= 22 * 60 + 30 || hm < 2 * 60, idle < 300 {
            once("late") { say("这么晚还在忙…我陪着你，不过别太晚哦。", for: 7) }
        }
        if activeMinutes >= 55 {
            activeMinutes = 0
            play(.stretch, 3)
            say(["坐了快一个小时了，起来伸个懒腰吧！", "喝口水，看看远处，眼睛会谢谢你。", "站起来走两步嘛，我帮你看着 Claude。"].randomElement()!, for: 7)
        }
    }

    /// 每天第一次见面：打招呼，顺便说说昨天
    private func dailyGreeting() {
        guard data.enabled, data.trip == nil else { return }
        once("greet") {
            let h = Calendar.current.component(.hour, from: Date())
            var s = h < 5 ? "这么晚还没睡呀。" : h < 11 ? "早上好！" : h < 13 ? "中午好！" : h < 18 ? "下午好！" : "晚上好！"
            if let fest = Self.festival(Date(), adopted: data.adoptedAt, days: daysTogether) { s = fest + " " + s }
            if let y = data.days[Self.dayKey(Date().addingTimeInterval(-86400))], y.tasks > 0 || y.tokens > 0 {
                s += "昨天我们一起做完了 \(y.tasks) 件事，我吃了 \(Self.tokenText(y.tokens)) token，已经写进日记了。"
            } else if daysTogether > 1 {
                s += "今天也一起加油吧。"
            }
            say(s, for: 8)
        }
    }

    private func chatter() {
        var pool: [String] = []
        if data.fullness < 30 { pool += ["肚子咕咕叫…让我吃点 token 吧。", "好饿，今天是不是还没开工？"] }
        if data.mood > 75 { pool += ["今天心情不错！", "跟你待在一起真好。", "我在想，Claude 会不会也想养只宠物。"] }
        if data.mood < 35 { pool += ["有点无聊…摸摸我？", "你今天还没摸我的头。"] }
        if data.energy < 30 { pool += ["好困…", "眼皮在打架。"] }
        if anyBusy { pool += ["我在帮你盯着 Claude。", "它敲字好快啊。"] }
        if !data.postcards.isEmpty { pool += ["上次去\(data.postcards.last!.place)，现在还想着呢。"] }
        pool += ["今天天气怎么样？我看不到窗外。", "右键我可以看看我的日记。", "我不吃饭，只吃 token。"]
        say(pool.randomElement()!, for: 5)
    }

    // MARK: 记账和保存

    private func bumpDay(_ f: (inout PetDay) -> Void) {
        var d = data.days[Self.today] ?? PetDay()
        f(&d)
        data.days[Self.today] = d
        if data.days.count > 120 {
            for k in data.days.keys.sorted().prefix(data.days.count - 120) { data.days[k] = nil }
        }
    }

    func save() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: w)
    }

    /// 退出时：同步写完再走
    func saveNowSync() {
        saveWork?.cancel()
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        if let d = try? enc.encode(data) { try? d.write(to: file, options: .atomic) }
    }

    func saveNow() {
        saveWork?.cancel()
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        guard let d = try? enc.encode(data) else { return }
        let f = file
        DispatchQueue.global(qos: .utility).async { try? d.write(to: f, options: .atomic) }
    }

    // MARK: 工具

    private static let dayFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()
    static func dayKey(_ d: Date) -> String { dayFmt.string(from: d) }
    static var today: String { dayKey(Date()) }
    static func hm(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d) }

    static func tokenText(_ n: Int) -> String {
        if n >= 10_000 { return String(format: n >= 100_000 ? "%.0f 万" : "%.1f 万", Double(n) / 10_000) }
        return "\(n)"
    }

    static func isNight(_ d: Date) -> Bool { let h = Calendar.current.component(.hour, from: d); return h >= 23 || h < 7 }
    static func isLateNight(_ d: Date) -> Bool { let h = Calendar.current.component(.hour, from: d); return h >= 23 || h < 4 }

    static func idleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    static func festival(_ d: Date, adopted: Date, days: Int) -> String? {
        let f = DateFormatter(); f.dateFormat = "MM-dd"
        let md = f.string(from: d)
        if md == f.string(from: adopted), days > 300 { return "今天是我们认识一周年！" }
        if days > 1, days % 100 == 0 { return "我们认识 \(days) 天啦！" }
        let table = ["01-01": "新年快乐！", "02-14": "情人节快乐，我爱你（的头）。", "05-01": "劳动节快乐，今天别太劳动了。",
                     "06-01": "儿童节快乐，今天允许你幼稚一下。", "10-01": "国庆快乐！", "12-24": "平安夜快乐！", "12-25": "圣诞快乐！",
                     "10-24": "今天是程序员节！"]
        return table[md]
    }
}

// MARK: 旅行目的地（本地写死的，不联网）

struct PetPlace { let place: String; let gift: String; let lines: [String] }

enum PetPlaces {
    static let all: [PetPlace] = [
        PetPlace(place: "杭州西湖", gift: "一片桂花", lines: ["在断桥边等了半天，没等到雪，等到一只鸭子。", "坐船的时候风把我吹跑了一小段，船夫把我捞回来了。"]),
        PetPlace(place: "厦门鼓浪屿", gift: "一张手绘明信片", lines: ["岛上的猫比游客还多，它们都不理我。", "听到有人在弹钢琴，我在门口坐了好久。"]),
        PetPlace(place: "成都", gift: "一小包火锅底料", lines: ["看到了熊猫，它在睡觉，睡得比我还香。", "吃了一口兔头，现在嘴还是麻的。"]),
        PetPlace(place: "西安", gift: "一个小兵马俑", lines: ["在城墙上骑了一段自行车，腿太短踩不到底。", "肉夹馍比我的脸还大。"]),
        PetPlace(place: "青岛", gift: "一个贝壳", lines: ["海水是咸的，我尝了一口，后悔了。", "看到好多红屋顶，像一盘番茄炒蛋。"]),
        PetPlace(place: "大理", gift: "一朵扎染小花", lines: ["洱海边躺了一下午，云走得比我还慢。", "苍山上的风很大，差点把我的呆毛吹直。"]),
        PetPlace(place: "苏州园林", gift: "一枚书签", lines: ["在园子里迷路了三次，每次都走回同一座假山。", "看见一扇圆圆的门，跟我的身材很像。"]),
        PetPlace(place: "重庆", gift: "一张轻轨票", lines: ["轻轨从楼里穿过去，我在里面喊了一声。", "导航说我在一楼，其实我在二十二楼。"]),
        PetPlace(place: "哈尔滨", gift: "一个冻梨", lines: ["太冷了，我差点冻成一块年糕。", "在冰雕旁边站了一会儿，有人以为我也是冰做的。"]),
        PetPlace(place: "三亚", gift: "一个椰子壳", lines: ["晒了一下午，现在是烤麻薯了。", "椰子掉下来砸在我旁边，吓得呆毛都竖起来了。"]),
        PetPlace(place: "敦煌", gift: "一小瓶沙子", lines: ["骑骆驼的时候一直在滑，最后是骆驼驮着我滑。", "晚上的星星多得数不过来，我数到一百就睡着了。"]),
        PetPlace(place: "桂林", gift: "一张山水画", lines: ["竹筏晃啊晃，我都快晕船了，但是风景真好看。", "这里的山长得像我的呆毛。"]),
        PetPlace(place: "北京胡同", gift: "一串糖葫芦", lines: ["跟着鸽子绕了一圈，又回到了起点。", "大爷请我喝了一碗豆汁，我还在想它的味道。"]),
        PetPlace(place: "上海外滩", gift: "一张夜景照片", lines: ["晚上的灯一下子全亮了，我叫出了声。", "人太多了，我被挤到了江边，只好看了一晚上的船。"]),
        PetPlace(place: "黄山", gift: "一块小石头", lines: ["爬了好多台阶，最后是被缆车带上去的。", "云海就在脚底下，我差点想跳进去。"]),
        PetPlace(place: "拉萨", gift: "一条小经幡", lines: ["天特别蓝，蓝得像你的编辑器背景。", "走两步就要歇一下，这里的空气太稀了。"]),
        PetPlace(place: "长沙", gift: "一杯奶茶的吸管", lines: ["排了一个小时的队，奶茶真的好喝。", "臭豆腐闻着臭，吃着香，跟有些代码一样。"]),
        PetPlace(place: "乌镇", gift: "一块蓝印花布", lines: ["坐在河边看摇橹船，船上的人跟我挥手。", "晚上的灯照在水里，有两个乌镇。"]),
        PetPlace(place: "武汉", gift: "一盒热干面", lines: ["过早吃了一碗热干面，芝麻酱糊了一脸。", "在长江大桥上吹风，桥下的船好小。"]),
        PetPlace(place: "云南的一片茶园", gift: "一小袋茶叶", lines: ["跟采茶的阿姨学了半天，只采了三片。", "雨后的茶山全是雾，我在里面走丢了一下。"]),
        PetPlace(place: "公司楼下的便利店", gift: "一根关东煮签子", lines: ["没走远，就在楼下转了转。关东煮的萝卜很入味。", "店员问我要不要袋子，我说我自己就是袋子。"]),
        PetPlace(place: "隔壁工位", gift: "一颗薄荷糖", lines: ["看了看别人的屏幕，他们也在跟 Claude 聊天。", "隔壁桌有盆多肉，我们聊了一会儿。"]),
    ]
}

// MARK: 日记：按当天发生的事拼出来

enum PetDiary {
    static func text(day key: String, d: PetDay, name: String) -> String {
        var seed = key.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        func pick(_ a: [String]) -> String { seed = (seed &* 1103515245 &+ 12345) & 0x7fffffff; return a[seed % a.count] }
        var parts: [String] = []
        if d.tokens > 0 {
            let t = PetStore.tokenText(d.tokens)
            let full = d.tokens > 500_000 ? pick(["撑得走不动路。", "肚子圆得像个球。"])
                : d.tokens > 100_000 ? pick(["吃得饱饱的。", "刚刚好。"]) : pick(["有点没吃饱。", "吃了个半饱。"])
            parts.append("今天吃了 \(t) token，" + full)
        } else {
            parts.append(pick(["今天没怎么开工，我吃了点零食。", "今天比较清闲。"]))
        }
        if d.tasks > 0 { parts.append(pick(["陪你做完了 \(d.tasks) 件事。", "我们一起做完了 \(d.tasks) 件事。"]) + (d.tasks >= 15 ? "你今天好拼。" : "")) }
        if d.waits > 0 { parts.append("有 \(d.waits) 次 Claude 等你确认，我都帮你喊了。") }
        if d.pets > 0 { parts.append(d.pets >= 10 ? "被摸了 \(d.pets) 次头，头发都乱了，但是很开心。" : "被摸了 \(d.pets) 次头。") }
        if d.snacks > 0 { parts.append("吃了 \(d.snacks) 份零食。") }
        if !d.trips.isEmpty { parts.append("出门去了\(d.trips.joined(separator: "、"))。") }
        if d.sick { parts.append(pick(["生了一场小病，吃了药好多了。", "今天有点不舒服，谢谢你照顾我。"])) }
        if d.lateNight { parts.append(pick(["你熬夜了，我也陪着没睡。下次早点休息吧。", "很晚了你还在忙，我有点心疼。"])) }
        parts.append(pick(["明天也要一起加油。", "就这样，晚安。", "今天也是被需要的一天。", "\(name)，记于今天。"]))
        return parts.joined()
    }
}

// MARK: 仅用于测试：DUIHUATAI_PET_SCRIPT=1 按顺序走一遍各种行为，把状态打到 stderr；DUIHUATAI_PET_SELFSHOT=目录 顺便截浮窗
extension PetStore {
    func runTestScript() {
        func log(_ tag: String) {
            let d = data
            FileHandle.standardError.write("[\(tag)] pose=\(pose.rawValue) bubble=\(bubble ?? "-") full=\(Int(d.fullness)) mood=\(Int(d.mood)) aff=\(String(format: "%.1f", d.affection)) sick=\(d.sick) trip=\(d.trip?.place ?? "-") cards=\(d.postcards.count) today=\(d.days[Self.today].map { "tok\($0.tokens)/task\($0.tasks)/pet\($0.pets)/snack\($0.snacks)" } ?? "-")\n".data(using: .utf8)!)
        }
        let steps: [(Double, String, () -> Void)] = [
            (3, "greet", {}),
            (4, "pat", { self.pat() }),
            (7, "poke4", { self.poke(); self.poke(); self.poke(); self.poke() }),
            (10, "snack", { self.feedSnack() }),
            (13, "eat", { self.finishedTurn(tokens: 30000, ok: true, error: false) }),
            (16, "travel", { self.goTravel(minutes: 1) }),
            (21, "away", {}),
            (23, "back", { self.callBack() }),
            (26, "starve", { self.data.fullness = 10; self.data.hungrySince = Date().addingTimeInterval(-5 * 3600); self.minute() }),
            (29, "medicine", { self.giveMedicine() }),
            (33, "medicine2", { self.data.fullness = 50; self.data.sick = true; self.giveMedicine() }),
            (37, "after", {}),
            (38, "movehost", { if let h = PetWindow.shared.host { h.setFrameOrigin(CGPoint(x: h.frame.minX - 120, y: h.frame.minY - 60)) } }),
            (39, "resizehost", { if let h = PetWindow.shared.host { var f = h.frame; f.size.width -= 100; f.size.height -= 40; h.setFrame(f, display: true) } }),
        ]
        for (at, tag, f) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + at) {
                f()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    log(tag)
                    PetWindow.shared.selfShot(tag)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 41) { self.saveNowSync(); exit(0) }
    }
}
