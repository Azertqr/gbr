// Nyx Menu — Grand Battle Royale (iOS, Unity IL2CPP) — FIXED BUILD
// Correctifs majeurs appliques :
// 1. ASLR Slide : sur iOS, _dyld_get_image_header(i) inclut le header __TEXT (0x100000000).
//    Comme les RVA de dump.cs sur iOS contiennent souvent deja ou non la base 0x100000000,
//    on normalise l'adresse via _dyld_get_image_vmaddr_slide(i) et un masque de RVA propre.
// 2. Patch memoire iOS (XNU W^X) : mprotect(..., PROT_READ|PROT_WRITE|PROT_EXEC) echoue toujours
//    sur iOS sans jailbreak/entitlement dynamique. Remplace par vm_protect avec VM_PROT_COPY
//    (Copy-on-Write page) + remise en RX + sys_icache_invalidate obligatoire sur ARM64.
// 3. Cablage UI : ApplyInfiniteHealth(v) n'etait meme pas appele dans sw:(UISwitch*)s (tag 3) !
// 4. Securite loadAPI() : appelee automatiquement avant tout patch si l'utilisateur active
//    les switchs avant que coreTick() ait fini son init.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdint.h>
#include <string.h>
#include <string>
#include <vector>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <libkern/OSCacheControl.h>
#include <sys/mman.h>
#include <unistd.h>

// ============================ CORE BEGIN ============================

typedef void* (*fn_getGameInstance)(void);
typedef void (*fn_void0)(void* self);
typedef void (*fn_void1_int)(void* self, int32_t a);

static uintptr_t g_gbrBase = 0;       // Header __TEXT de l'image "gbr"
static uintptr_t g_gbrSlide = 0;      // Slide ASLR de l'image "gbr"
static std::string g_lastMissingSymbol;

// RVA retrouvees dans dump_1.cs pour Grand Battle Royale 3.5.2.
static const uintptr_t RVA_GAME_INSTANCE_GETTER = 0x19138DC;
static const uintptr_t RVA_REVIVE_AS_HUMAN       = 0x1BF1F60;   // NetworkPlayer.ReviveAsHuman()
static const uintptr_t RVA_REVIVE_AS_ZOMBIE      = 0x1BE8C00;   // NetworkPlayer.ReviveAsZombie()
static const uintptr_t RVA_ASSIGN_SKIN           = 0x1BDEE34;   // NetworkPlayer.AssignSkinFromZombiesDatabase(int)
static const uintptr_t RVA_RECEIVE_DAMAGE        = 0x1BE1950;   // NetworkPlayer.ReceiveDamage(float, int, ItemType, int, Vector3)

struct Vec3f { float x, y, z; };
typedef void (*fn_receiveDamage)(void* self, float damage, int32_t attackerId, int32_t itemType, int32_t unk, Vec3f pos);

// ---- Anti-Cheat Toolkit & Game AC ----
static const uintptr_t RVA_AC[] = {
    0x1725144,   // ObscuredCheatingDetector.Awake
    0x172BD98,   // SpeedHackDetector.Awake
    0x172B998,   // SpeedHackDetector.Update
    0x1734758,   // TimeCheatingDetector.Awake
    0x173CDAC,   // WallHackDetector.Awake
    0x173E0C4,   // WallHackDetector.FixedUpdate
    0x173F024,   // WallHackDetector.Update
    0x172230C,   // ActDetectorBase.Start
    0x1722414,   // ActDetectorBase.OnEnable
    0x1991DBC,   // Game.<naughtyReason coroutine>.MoveNext()
    0x1908DC0,   // Game.NaughtyToolkitCallback()
};
static const int RVA_AC_COUNT = sizeof(RVA_AC) / sizeof(RVA_AC[0]);
static uint32_t g_acOriginal[RVA_AC_COUNT];
static bool g_acPatched[RVA_AC_COUNT] = {false};
static bool g_acAttempted = false;
static int g_acSucceeded = 0;

static uint32_t g_healthOriginal = 0;
static bool g_healthPatched = false;

static bool FindImageBaseAndSlide(const char* needle) {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char* name = _dyld_get_image_name(i);
        if (name && strstr(name, needle)) {
            g_gbrBase  = (uintptr_t)_dyld_get_image_header(i);
            g_gbrSlide = (uintptr_t)_dyld_get_image_vmaddr_slide(i);
            return (g_gbrBase != 0);
        }
    }
    return false;
}

static bool loadAPI() {
    if (g_gbrBase != 0) return true;
    // Cherche "/gbr" ou "UnityFramework" au cas ou le binaire change de structure
    if (!FindImageBaseAndSlide("/gbr") && !FindImageBaseAndSlide("UnityFramework")) {
        g_lastMissingSymbol = "image gbr pas encore chargee";
        return false;
    }
    return true;
}

// Calcule l'adresse reelle en RAM que la RVA vienne d'un dump.cs (offset pur) ou d'IDA (0x100000000 + offset)
static inline uintptr_t RealAddr(uintptr_t rva) {
    if (rva >= 0x100000000ULL) {
        return g_gbrSlide + rva;
    }
    return g_gbrBase + rva;
}

// Patch memoire iOS ARM64 propre : contourne le W^X de XNU via VM_PROT_COPY + flush cache L1 I/D
static bool PatchBytes(uintptr_t addr, uint32_t newInstr, uint32_t* outOriginal) {
    if (!addr) return false;
    long pagesize = sysconf(_SC_PAGESIZE);
    uintptr_t pageStart = addr & ~(uintptr_t)(pagesize - 1);
    mach_port_t selfTask = mach_task_self();

    // 1. Passage en RW avec VM_PROT_COPY (cree une page privee Copy-on-Write autorisee sur iOS)
    kern_return_t kr = vm_protect(selfTask, (vm_address_t)pageStart, (vm_size_t)pagesize, FALSE,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) {
        // Fallback mprotect RW (sans EXEC, car RWX est interdit par XNU)
        if (mprotect((void*)pageStart, pagesize, PROT_READ | PROT_WRITE) != 0) {
            return false;
        }
    }

    // 2. Sauvegarde de l'instruction d'origine et ecriture du patch
    if (outOriginal) {
        *outOriginal = *(uint32_t*)addr;
    }
    *(uint32_t*)addr = newInstr;

    // 3. Remise de la page en RX (Read + Execute) pour que le CPU puisse executer le code
    kr = vm_protect(selfTask, (vm_address_t)pageStart, (vm_size_t)pagesize, FALSE,
                    VM_PROT_READ | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) {
        mprotect((void*)pageStart, pagesize, PROT_READ | PROT_EXEC);
    }

    // 4. Invalidation obligatoire du cache d'instructions ARM64
    sys_icache_invalidate((void*)addr, sizeof(uint32_t));
    return true;
}

static bool RestoreBytes(uintptr_t addr, uint32_t origInstr) {
    return PatchBytes(addr, origInstr, nullptr);
}

// Vie infinie : patche NetworkPlayer.ReceiveDamage (0x1BE1950) avec RET (0xD65F03C0)
// Exactement comme OFF_RECV_DMG (0xB53CC8) sur ton Main.cpp Android[span_0](start_span)[span_0](end_span).
static bool ApplyInfiniteHealth(bool on) {
    if (!loadAPI()) return false;
    uintptr_t addr = RealAddr(RVA_RECEIVE_DAMAGE);
    const uint32_t RET_ARM64 = 0xD65F03C0; // C0 03 5F D6 en little-endian

    if (on && !g_healthPatched) {
        g_healthPatched = PatchBytes(addr, RET_ARM64, &g_healthOriginal);
        return g_healthPatched;
    }
    if (!on && g_healthPatched) {
        if (RestoreBytes(addr, g_healthOriginal)) {
            g_healthPatched = false;
            return true;
        }
        return false;
    }
    return g_healthPatched == on;
}

static void ApplyAntiCheatBypass(bool on) {
    if (!loadAPI()) return;
    g_acAttempted = true;
    g_acSucceeded = 0;
    const uint32_t RET_ARM64 = 0xD65F03C0;

    for (int i = 0; i < RVA_AC_COUNT; i++) {
        uintptr_t addr = RealAddr(RVA_AC[i]);
        if (on) {
            if (!g_acPatched[i]) {
                g_acPatched[i] = PatchBytes(addr, RET_ARM64, &g_acOriginal[i]);
            }
            if (g_acPatched[i]) g_acSucceeded++;
        } else if (!on && g_acPatched[i]) {
            if (RestoreBytes(addr, g_acOriginal[i])) {
                g_acPatched[i] = false;
            }
        }
    }
}

struct Cfg {
    bool infiniteAmmo = false;
    bool oneHitKill = false;
    bool speed = false;
    float speedMul = 2.0f;
    bool infiniteHealth = false;
    bool antiCheatBypass = false;
};
static Cfg cfg;

static std::string g_status = "en attente du jeu...";

static struct {
    bool ready = false;
    void* f_gameInst = nullptr;
    // Offsets de champs 64-bit verifies (identiques a ton Main.cpp Android)[span_1](start_span)[span_1](end_span) :
    int game_Players   = 0x28;  // Game.playerList : List<NetworkPlayer>[span_2](start_span)[span_2](end_span)
    int np_Items       = 0x58;  // NetworkPlayer.items : Item[][span_3](start_span)[span_3](end_span)
    int it_Speed       = 0x30;  // Item.basicShootSpeed[span_4](start_span)[span_4](end_span)
    int it_Reload      = 0x34;  // Item.basicReloadSpeed[span_5](start_span)[span_5](end_span)
    int it_Range       = 0x40;  // Item.range[span_6](start_span)[span_6](end_span)
    int it_MaxAmmo     = 0x44;  // Item.maxAmo[span_7](start_span)[span_7](end_span)
    int it_CurAmmo     = 0x48;  // Item.currAmo[span_8](start_span)[span_8](end_span)
    int it_Damage      = 0x50;  // Item.itemDamage[span_9](start_span)[span_9](end_span)
    int np_IsLocal     = 0x2E8; // NetworkPlayer.isLocal (byte/bool)[span_10](start_span)[span_10](end_span)
    int np_MoveCtrl    = 0x2D8; // NetworkPlayer.MoveController
    int mc_WalkSpeed   = 0x1C;  // MoveController.m_WalkSpeed[span_11](start_span)[span_11](end_span)
    int mc_RunSpeed    = 0x20;  // MoveController.m_RunSpeed[span_12](start_span)[span_12](end_span)
    int mc_SprintSpeed = 0x24;  // MoveController.m_SprintSpeed[span_13](start_span)[span_13](end_span)
} g;

template <typename T> static inline T rd(void* o, int off) { return *(T*)((uint8_t*)o + off); }
template <typename T> static inline void wr(void* o, int off, T v) { *(T*)((uint8_t*)o + off) = v; }

static inline bool plausible(void* p) {
    uintptr_t v = (uintptr_t)p;
    return v > 0x100000000ULL && v < 0x7fffffffffffULL;
}

// Re-recupere Game.Instance dynamiquement a chaque tick car l'instance change quand on quitte/rejoint une room !
static bool refreshGameInstance() {
    if (!loadAPI()) {
        g_status = "en attente : " + g_lastMissingSymbol;
        return false;
    }
    fn_getGameInstance getInst = (fn_getGameInstance)RealAddr(RVA_GAME_INSTANCE_GETTER);
    void* game = getInst();
    if (!plausible(game)) {
        g.f_gameInst = nullptr;
        g.ready = false;
        g_status = "Dans le menu / En attente d'une partie...";
        return false;
    }
    g.f_gameInst = game;
    g.ready = true;
    g_status = "En partie (Game.Instance actif)";
    return true;
}

static std::vector<void*> playerObjs() {
    std::vector<void*> out;
    if (!g.ready || !plausible(g.f_gameInst)) return out;
    void* list = rd<void*>(g.f_gameInst, g.game_Players);
    if (!plausible(list)) return out;
    void* items = rd<void*>(list, 0x10);
    int32_t n = rd<int32_t>(list, 0x18);
    if (!plausible(items) || n <= 0 || n > 64) return out;
    for (int i = 0; i < n; i++) {
        void* np = rd<void*>(items, 0x20 + 8 * i);
        if (plausible(np)) out.push_back(np);
    }
    return out;
}

static void* getLocalPlayer() {
    for (void* np : playerObjs()) {
        if (rd<uint8_t>(np, g.np_IsLocal) != 0) return np;
    }
    return nullptr;
}

static int reviveAsHuman() {
    if (!refreshGameInstance()) return -1;
    void* lp = getLocalPlayer();
    if (!plausible(lp)) return -1;
    ((fn_void0)RealAddr(RVA_REVIVE_AS_HUMAN))(lp);
    return 0;
}

static int reviveAsZombie() {
    if (!refreshGameInstance()) return -1;
    void* lp = getLocalPlayer();
    if (!plausible(lp)) return -1;
    ((fn_void0)RealAddr(RVA_REVIVE_AS_ZOMBIE))(lp);
    return 0;
}

static int nextSkin() {
    static int32_t skinId = 0;
    if (!refreshGameInstance()) return -1;
    void* lp = getLocalPlayer();
    if (!plausible(lp)) return -1;
    skinId = (skinId + 1) % 164; // 164 skins comme sur ton mod Android[span_14](start_span)[span_14](end_span)
    ((fn_void1_int)RealAddr(RVA_ASSIGN_SKIN))(lp, skinId);
    return skinId;
}

static void coreTick() {
    if (!refreshGameInstance()) return;

    void* lp = getLocalPlayer();
    if (!plausible(lp)) return;

    // --- 1. Vitesse (joueur local uniquement) ---
    static void* lastMC = nullptr;
    static float baseWalk = 0, baseRun = 0, baseSprint = 0;
    static bool speedApplied = false;

    void* mc = rd<void*>(lp, g.np_MoveCtrl);
    if (plausible(mc)) {
        if (mc != lastMC) {
            lastMC = mc;
            speedApplied = false;
            baseWalk   = rd<float>(mc, g.mc_WalkSpeed);
            baseRun    = rd<float>(mc, g.mc_RunSpeed);
            baseSprint = rd<float>(mc, g.mc_SprintSpeed);
            if (baseWalk   <= 0.f || baseWalk   > 50.f) baseWalk   = 5.f;
            if (baseRun    <= 0.f || baseRun    > 50.f) baseRun    = 8.f;
            if (baseSprint <= 0.f || baseSprint > 50.f) baseSprint = 12.f;
        }
        if (cfg.speed) {
            wr<float>(mc, g.mc_WalkSpeed,   baseWalk   * cfg.speedMul);
            wr<float>(mc, g.mc_RunSpeed,    baseRun    * cfg.speedMul);
            wr<float>(mc, g.mc_SprintSpeed, baseSprint * cfg.speedMul);
            speedApplied = true;
        } else if (speedApplied) {
            wr<float>(mc, g.mc_WalkSpeed,   baseWalk);
            wr<float>(mc, g.mc_RunSpeed,    baseRun);
            wr<float>(mc, g.mc_SprintSpeed, baseSprint);
            speedApplied = false;
        }
    }

    // --- 2. Munitions infinies & One Hit Kill (sur TON joueur local uniquement !) ---
    if (!cfg.infiniteAmmo && !cfg.oneHitKill) return;

    void* itemsArr = rd<void*>(lp, g.np_Items);
    if (!plausible(itemsArr)) return;
    int32_t n = rd<int32_t>(itemsArr, 0x18);
    if (n <= 0 || n > 10) return;

    for (int j = 0; j < n; j++) {
        void* item = rd<void*>(itemsArr, 0x20 + 8 * j);
        if (!plausible(item)) continue;
        if (cfg.infiniteAmmo) {
            wr<int32_t>(item, g.it_MaxAmmo, 9999);
            wr<int32_t>(item, g.it_CurAmmo, 9999);
        }
        if (cfg.oneHitKill) {
            wr<int32_t>(item, g.it_Damage, 9999);
        }
    }
}

// ============================= CORE END =============================
#pragma mark - Helpers UI

static UIColor* accent() { return [UIColor colorWithRed:0.95 green:0.55 blue:0.15 alpha:1.0]; }

static void haptic() {
    UIImpactFeedbackGenerator* h = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [h impactOccurred];
}

static UIWindow* gameWindow() {
    UIWindow* fallback = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene* sc in [UIApplication sharedApplication].connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow* w in ((UIWindowScene*)sc).windows) {
                if (w.isKeyWindow) return w;
                if (!fallback) fallback = w;
            }
        }
    }
    if (fallback) return fallback;
    return [UIApplication sharedApplication].keyWindow;
}

#pragma mark - Menu

@interface NyxGBR_UI : NSObject
@property (nonatomic, strong) UIWindow* host;
@property (nonatomic, strong) UIButton* fab;
@property (nonatomic, strong) UIVisualEffectView* panel;
@property (nonatomic, strong) UILabel* statusLabel;
@property (nonatomic, strong) UILabel* speedLabel;
@property (nonatomic, copy) NSString* msg;
@property (nonatomic, assign) CFAbsoluteTime msgTime;
+ (instancetype)shared;
- (void)attach:(UIWindow*)w;
- (void)refresh;
- (void)keepOnTop;
@end

@implementation NyxGBR_UI

+ (instancetype)shared {
    static NyxGBR_UI* s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [NyxGBR_UI new]; });
    return s;
}

- (UILabel*)label:(NSString*)t size:(CGFloat)sz bold:(BOOL)b color:(UIColor*)c {
    UILabel* l = [UILabel new];
    l.text = t;
    l.font = b ? [UIFont boldSystemFontOfSize:sz] : [UIFont systemFontOfSize:sz];
    l.textColor = c;
    return l;
}

- (CGFloat)toggle:(NSString*)t tag:(NSInteger)tag y:(CGFloat)y in:(UIScrollView*)sv {
    UILabel* l = [self label:t size:15 bold:NO color:[UIColor whiteColor]];
    l.frame = CGRectMake(16, y, 230, 31);
    [sv addSubview:l];
    UISwitch* s = [UISwitch new];
    s.tag = tag;
    s.onTintColor = accent();
    s.center = CGPointMake(300 - 16 - s.bounds.size.width / 2, y + 15.5);
    [s addTarget:self action:@selector(sw:) forControlEvents:UIControlEventValueChanged];
    [sv addSubview:s];
    return y + 40;
}

- (UIButton*)button:(NSString*)t sel:(SEL)sel frame:(CGRect)f in:(UIScrollView*)sv {
    UIButton* b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = f;
    b.backgroundColor = [UIColor colorWithRed:0.25 green:0.14 blue:0.04 alpha:0.95];
    b.layer.borderWidth = 1.0;
    b.layer.borderColor = accent().CGColor;
    b.layer.cornerRadius = 9;
    b.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    [b setTitle:t forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    [sv addSubview:b];
    return b;
}

- (UISlider*)slider:(NSInteger)tag min:(float)mn max:(float)mx val:(float)v y:(CGFloat)y in:(UIScrollView*)sv {
    UISlider* sl = [[UISlider alloc] initWithFrame:CGRectMake(16, y, 268, 28)];
    sl.tag = tag; sl.minimumValue = mn; sl.maximumValue = mx; sl.value = v;
    sl.minimumTrackTintColor = accent();
    [sl addTarget:self action:@selector(slide:) forControlEvents:UIControlEventValueChanged];
    [sv addSubview:sl];
    return sl;
}

- (void)attach:(UIWindow*)w {
    self.host = w;
    CGFloat s = 46;
    UIEdgeInsets si = w.safeAreaInsets;

    self.fab = [UIButton buttonWithType:UIButtonTypeCustom];
    self.fab.frame = CGRectMake(si.left + 14, si.top + 80, s, s);
    self.fab.backgroundColor = [UIColor colorWithRed:0.18 green:0.08 blue:0.02 alpha:0.88];
    self.fab.layer.cornerRadius = s / 2;
    self.fab.layer.borderWidth = 1.5;
    self.fab.layer.borderColor = accent().CGColor;
    self.fab.titleLabel.font = [UIFont boldSystemFontOfSize:20];
    [self.fab setTitle:@"N" forState:UIControlStateNormal];
    [self.fab setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [self.fab addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer* pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)];
    [self.fab addGestureRecognizer:pan];
    [w addSubview:self.fab];

    [self buildPanel];
}

- (void)buildPanel {
    CGFloat W = 300, H = 480;
    UIBlurEffect* blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
    self.panel = [[UIVisualEffectView alloc] initWithEffect:blur];
    self.panel.frame = CGRectMake(0, 0, W, H);
    self.panel.layer.cornerRadius = 18;
    self.panel.clipsToBounds = YES;
    self.panel.layer.borderWidth = 1;
    self.panel.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.12].CGColor;
    self.panel.hidden = YES;

    UILabel* title = [self label:@"Nyx Menu - GBR" size:18 bold:YES color:[UIColor whiteColor]];
    title.frame = CGRectMake(16, 12, 200, 24);
    [self.panel.contentView addSubview:title];
    UILabel* sub = [self label:@"v3.5.2 - iOS RVA + vm_protect" size:11 bold:NO color:[UIColor colorWithWhite:1 alpha:0.5]];
    sub.frame = CGRectMake(16, 36, 200, 14);
    [self.panel.contentView addSubview:sub];

    UIButton* close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(W - 52, 8, 44, 40);
    [close setTitle:@"X" forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    [close setTitleColor:[UIColor colorWithWhite:1 alpha:0.7] forState:UIControlStateNormal];
    [close addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    [self.panel.contentView addSubview:close];

    UIScrollView* sv = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 58, W, H - 58)];
    [self.panel.contentView addSubview:sv];

    CGFloat y = 10;
    y = [self toggle:@"Munitions infinies" tag:0 y:y in:sv];
    y = [self toggle:@"One Hit Kill" tag:1 y:y in:sv];
    y = [self toggle:@"Vitesse" tag:2 y:y in:sv];
    y = [self toggle:@"Vie infinie (God Mode)" tag:3 y:y in:sv];
    y = [self toggle:@"Anti-Cheat Bypass" tag:4 y:y in:sv];

    self.speedLabel = [self label:[NSString stringWithFormat:@"Multiplicateur : x%.1f", cfg.speedMul]
                             size:11 bold:NO color:[UIColor colorWithWhite:1 alpha:0.65]];
    self.speedLabel.frame = CGRectMake(16, y, 260, 14);
    [sv addSubview:self.speedLabel];
    [self slider:100 min:1.0 max:5.0 val:cfg.speedMul y:y + 16 in:sv];
    y += 48;

    [self button:@"Reviv humain" sel:@selector(reviveHumanTap) frame:CGRectMake(16, y, 130, 36) in:sv];
    [self button:@"Reviv zombie" sel:@selector(reviveZombieTap) frame:CGRectMake(154, y, 130, 36) in:sv];
    y += 44;
    [self button:@"Skin suivant" sel:@selector(skinTap) frame:CGRectMake(16, y, W - 32, 36) in:sv];
    y += 44;

    self.statusLabel = [self label:@"" size:11 bold:NO color:[UIColor colorWithWhite:1 alpha:0.5]];
    self.statusLabel.numberOfLines = 3;
    self.statusLabel.frame = CGRectMake(16, y + 10, W - 32, 50);
    [sv addSubview:self.statusLabel];

    sv.contentSize = CGSizeMake(W, y + 70);
    [self.host addSubview:self.panel];
}

- (void)togglePanel {
    haptic();
    if (self.panel.hidden) {
        CGRect b = self.host.bounds;
        CGFloat W = self.panel.bounds.size.width;
        CGFloat H = self.panel.bounds.size.height;
        self.panel.frame = CGRectMake((b.size.width - W) / 2, (b.size.height - H) / 2, W, H);
        self.panel.hidden = NO;
        [self.host bringSubviewToFront:self.panel];
        [self.host bringSubviewToFront:self.fab];
        [self refresh];
    } else {
        self.panel.hidden = YES;
    }
}

- (void)drag:(UIPanGestureRecognizer*)gr {
    CGPoint t = [gr translationInView:self.host];
    CGPoint c = self.fab.center;
    c.x = MAX(23, MIN(self.host.bounds.size.width - 23, c.x + t.x));
    c.y = MAX(23, MIN(self.host.bounds.size.height - 23, c.y + t.y));
    self.fab.center = c;
    [gr setTranslation:CGPointMake(0, 0) inView:self.host];
}

- (void)sw:(UISwitch*)s {
    bool v = s.on;
    if (s.tag == 0) {
        cfg.infiniteAmmo = v;
        [self say:v ? @"Munitions infinies : ON" : @"Munitions infinies : OFF"];
    }
    if (s.tag == 1) {
        cfg.oneHitKill = v;
        [self say:v ? @"One Hit Kill : ON" : @"One Hit Kill : OFF"];
    }
    if (s.tag == 2) {
        cfg.speed = v;
        [self say:v ? @"Speed Hack : ON" : @"Speed Hack : OFF"];
    }
    if (s.tag == 3) {
        cfg.infiniteHealth = v;
        bool ok = ApplyInfiniteHealth(v);
        if (ok) {
            [self say:v ? @"God Mode actif (ReceiveDamage RET)" : @"God Mode desactive"];
        } else {
            [s setOn:!v animated:YES];
            cfg.infiniteHealth = !v;
            [self say:@"Echec patch ReceiveDamage (vm_protect)"];
        }
    }
    if (s.tag == 4) {
        cfg.antiCheatBypass = v;
        ApplyAntiCheatBypass(v);
        [self say:[NSString stringWithFormat:@"AC patch : %d/%d reussis (vm_protect)", g_acSucceeded, RVA_AC_COUNT]];
    }
    haptic();
    [self refresh];
}

- (void)slide:(UISlider*)s {
    cfg.speedMul = roundf(s.value * 10.f) / 10.f;
    self.speedLabel.text = [NSString stringWithFormat:@"Multiplicateur : x%.1f", cfg.speedMul];
}

- (void)say:(NSString*)m {
    self.msg = m;
    self.msgTime = CFAbsoluteTimeGetCurrent();
}

- (void)reviveHumanTap {
    haptic();
    [self say:reviveAsHuman() == 0 ? @"Reviv humain envoye" : @"Impossible : pas en partie"];
    [self refresh];
}
- (void)reviveZombieTap {
    haptic();
    [self say:reviveAsZombie() == 0 ? @"Reviv zombie envoye" : @"Impossible : pas en partie"];
    [self refresh];
}
- (void)skinTap {
    haptic();
    int r = nextSkin();
    [self say:r >= 0 ? [NSString stringWithFormat:@"Skin %d envoye", r] : @"Impossible : pas en partie"];
    [self refresh];
}

- (void)refresh {
    if (self.panel.hidden) return;
    if (self.msg && (CFAbsoluteTimeGetCurrent() - self.msgTime) < 4.0) {
        self.statusLabel.text = self.msg;
    } else {
        std::string st = g_status;
        self.statusLabel.text = [NSString stringWithFormat:@"%s", st.c_str()];
    }
}

- (void)keepOnTop {
    if (!self.host) return;
    if (!self.panel.hidden) [self.host bringSubviewToFront:self.panel];
    [self.host bringSubviewToFront:self.fab];
}

@end

#pragma mark - Entree

static void tryInstallUI() {
    UIWindow* w = gameWindow();
    if (!w) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ tryInstallUI(); });
        return;
    }
    [[NyxGBR_UI shared] attach:w];
}

__attribute__((constructor)) static void nyx_gbr_entry(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        loadAPI();
        // Auto-activation de l'Anti-Cheat Bypass des le boot comme sur ton Main.cpp Android[span_15](start_span)[span_15](end_span)
        cfg.antiCheatBypass = true;
        ApplyAntiCheatBypass(true);

        tryInstallUI();
        [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer* t) { coreTick(); }];
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer* t) {
            [[NyxGBR_UI shared] refresh];
            [[NyxGBR_UI shared] keepOnTop];
        }];
    });
}
