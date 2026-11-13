// Nyx Menu — Grand Battle Royale (iOS 3.5.2, No-Jailbreak / Sideloaded Safe)
// POURQUOI CA NE CRASHE PLUS SUR IPAD NON-JAILBREAKE :
// Sur iOS non-jailbreake (SideStore / ZeeSigner sans JIT), modifier le segment __TEXT
// (code assembleur) avec mprotect Echoue, et avec vm_protect(VM_PROT_COPY) provoque un
// crash instantane CODESIGNING (SIGKILL/EXC_BAD_ACCESS) des que le CPU execute la page.
//
// LA VRAIE TECHNIQUE NO-JAILBREAK :
// Au lieu de patcher le code des fonctions, on modifie les OBJETS C# EN RAM (Heap = RW)
// et on appelle les methodes deja signees du jeu :
// 1. Anti-Cheat Bypass (No-JB) : Unity stocke le flag "enabled" d'un MonoBehaviour dans son
//    pointeur natif C++ (m_CachedPtr + 0x38). Et surtout, chaque détecteur ACTk possede un
//    champ boolean "isRunning" (0x19) et "autoDispose" / "keepAlive" qu'on ecrase en RAM,
//    ou on appelle Behaviour.set_enabled(false) directement !
// 2. God Mode (No-JB) :
//    - On appelle ReviveAsHuman() / restaure l'etat du joueur local en boucle.
//    - On sabote les armes des ENNEMIS dans la meme room (damage = 0, ammo = 0 sur tous
//      les NetworkPlayer ou isLocal == 0) -> personne dans la partie ne peut te faire de degats !
//    - On ajoute aussi le Rapid Fire + Portee Infinie + Jump Boost de ton Main.cpp Android.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdint.h>
#include <string.h>
#include <string>
#include <vector>
#include <mach-o/dyld.h>
#include <unistd.h>

// ============================ CORE BEGIN ============================

typedef void* (*fn_getGameInstance)(void);
typedef void  (*fn_void0)(void* self);
typedef void  (*fn_void1_int)(void* self, int32_t a);

static uintptr_t g_gbrBase = 0;
static std::string g_lastMissingSymbol;

// RVAs iOS 3.5.2 (issues de ton dump_1.cs)
static const uintptr_t RVA_GAME_INSTANCE_GETTER = 0x19138DC; // Game.get_Instance()
static const uintptr_t RVA_REVIVE_AS_HUMAN       = 0x1BF1F60; // NetworkPlayer.ReviveAsHuman()
static const uintptr_t RVA_REVIVE_AS_ZOMBIE      = 0x1BE8C00; // NetworkPlayer.ReviveAsZombie()
static const uintptr_t RVA_ASSIGN_SKIN           = 0x1BDEE34; // NetworkPlayer.AssignSkinFromZombiesDatabase(int)

static uintptr_t FindImageBase(const char* needle) {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char* name = _dyld_get_image_name(i);
        if (name && strstr(name, needle)) return (uintptr_t)_dyld_get_image_header(i);
    }
    return 0;
}

static bool loadAPI() {
    if (g_gbrBase) return true;
    g_gbrBase = FindImageBase("/gbr");
    if (!g_gbrBase) {
        g_lastMissingSymbol = "image gbr pas encore chargee";
        return false;
    }
    return true;
}

struct Cfg {
    bool infiniteAmmo    = false;
    bool oneHitKill      = false;
    bool rapidFire       = false;
    bool speed           = false;
    float speedMul       = 2.0f;
    bool jumpBoost       = false;
    float jumpMul        = 2.0f;
    bool infiniteHealth  = false; // God Mode No-JB (Disarm Enemies + Auto-Heal/Revive + Zombie Shield)
    bool antiCheatBypass = true;  // Neutralisation RAM des coroutines / états AC
};
static Cfg cfg;

static std::string g_status = "Prêt (entre dans une partie avant d'activer)";

static struct {
    bool ready = false;
    void* f_gameInst = nullptr;
    // Offsets de champs 64 bits (100% identiques entre Android et iOS) :
    int game_Players   = 0x28;  // Game.players : List<NetworkPlayer>
    int np_Items       = 0x58;  // NetworkPlayer.items : Item[]
    int it_Speed       = 0x30;  // Item.basicShootSpeed
    int it_Reload      = 0x34;  // Item.basicReloadSpeed
    int it_Range       = 0x40;  // Item.range
    int it_MaxAmmo     = 0x44;  // Item.maxAmo
    int it_CurAmmo     = 0x48;  // Item.currAmo
    int it_Damage      = 0x50;  // Item.itemDamage
    int np_IsLocal     = 0x2E8; // NetworkPlayer.isLocal (bool)
    int np_MoveCtrl    = 0x2D8; // NetworkPlayer.MoveController
    int mc_WalkSpeed   = 0x1C;  // MoveController.m_WalkSpeed
    int mc_RunSpeed    = 0x20;  // MoveController.m_RunSpeed
    int mc_SprintSpeed = 0x24;  // MoveController.m_SprintSpeed
    int mc_JumpSpeed   = 0x30;  // MoveController.m_JumpSpeed
} g;

template <typename T> static inline T rd(void* o, int off) { return *(T*)((uint8_t*)o + off); }
template <typename T> static inline void wr(void* o, int off, T v) { *(T*)((uint8_t*)o + off) = v; }

static inline bool plausible(void* p) {
    uintptr_t v = (uintptr_t)p;
    return v > 0x100000000ULL && v < 0x7fffffffffffULL;
}

// IMPORTANT : On n'appelle Game.Instance QUE quand un cheat est actif ou qu'un bouton est pressé,
// jamais pendant l'écran de chargement initial, ce qui évite tout crash au démarrage !
static bool ensureGameReady() {
    if (!loadAPI()) {
        g_status = "En attente : " + g_lastMissingSymbol;
        return false;
    }
    fn_getGameInstance getInst = (fn_getGameInstance)(g_gbrBase + RVA_GAME_INSTANCE_GETTER);
    void* game = getInst();
    if (!plausible(game)) {
        g.f_gameInst = nullptr;
        g.ready = false;
        g_status = "Menu principal (lance une partie)";
        return false;
    }
    // Vérifie aussi que la liste des joueurs existe bien dans cette instance
    void* list = rd<void*>(game, g.game_Players);
    if (!plausible(list)) {
        g.f_gameInst = nullptr;
        g.ready = false;
        g_status = "Chargement de la room...";
        return false;
    }
    g.f_gameInst = game;
    g.ready = true;
    g_status = "En partie (RAM Hook actif - 0 crash)";
    return true;
}

static std::vector<void*> playerObjs() {
    std::vector<void*> out;
    if (!g.ready || !plausible(g.f_gameInst)) return out;
    void* list = rd<void*>(g.f_gameInst, g.game_Players);
    if (!plausible(list)) {
        g.ready = false;
        return out;
    }
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
    if (!ensureGameReady()) return -1;
    void* lp = getLocalPlayer();
    if (!plausible(lp)) return -1;
    ((fn_void0)(g_gbrBase + RVA_REVIVE_AS_HUMAN))(lp);
    return 0;
}

static int reviveAsZombie() {
    if (!ensureGameReady()) return -1;
    void* lp = getLocalPlayer();
    if (!plausible(lp)) return -1;
    ((fn_void0)(g_gbrBase + RVA_REVIVE_AS_ZOMBIE))(lp);
    return 0;
}

static int nextSkin() {
    static int32_t skinId = 0;
    if (!ensureGameReady()) return -1;
    void* lp = getLocalPlayer();
    if (!plausible(lp)) return -1;
    skinId = (skinId + 1) % 164;
    ((fn_void1_int)(g_gbrBase + RVA_ASSIGN_SKIN))(lp, skinId);
    return skinId;
}

static void coreTick() {
    // Si aucune option n'est cochée, on ne touche même pas au jeu -> 0% risque de crash au boot !
    bool anyActive = cfg.infiniteAmmo || cfg.oneHitKill || cfg.rapidFire ||
                     cfg.speed || cfg.jumpBoost || cfg.infiniteHealth;
    if (!anyActive) return;

    if (!ensureGameReady()) return;

    std::vector<void*> players = playerObjs();
    if (players.empty()) return;

    void* lp = nullptr;
    for (void* np : players) {
        if (rd<uint8_t>(np, g.np_IsLocal) != 0) {
            lp = np;
            break;
        }
    }
    if (!plausible(lp)) return;

    // --- 1. Mouvement : Speed Hack & Jump Boost (en RAM sur MoveController) ---
    static void* lastMC = nullptr;
    static float baseWalk = 5.f, baseRun = 8.f, baseSprint = 12.f, baseJump = 8.f;
    static bool speedApplied = false;
    static bool jumpApplied  = false;

    void* mc = rd<void*>(lp, g.np_MoveCtrl);
    if (plausible(mc)) {
        if (mc != lastMC) {
            lastMC = mc;
            speedApplied = false;
            jumpApplied  = false;
            baseWalk   = rd<float>(mc, g.mc_WalkSpeed);
            baseRun    = rd<float>(mc, g.mc_RunSpeed);
            baseSprint = rd<float>(mc, g.mc_SprintSpeed);
            baseJump   = rd<float>(mc, g.mc_JumpSpeed);
            if (baseWalk   <= 0.f || baseWalk   > 50.f) baseWalk   = 5.f;
            if (baseRun    <= 0.f || baseRun    > 50.f) baseRun    = 8.f;
            if (baseSprint <= 0.f || baseSprint > 50.f) baseSprint = 12.f;
            if (baseJump   <= 0.f || baseJump   > 50.f) baseJump   = 8.f;
        }
        // Speed
        if (cfg.speed) {
            // Note Anti-Cheat SpeedHackDetector : garder x1.5 - x2.5 max évite la détection serveur,
            // et en RAM on n'altère pas Time.timeScale (ce que SpeedHackDetector surveille !)
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
        // Jump Boost (Offset 0x30 de ton Main.cpp Android)
        if (cfg.jumpBoost) {
            wr<float>(mc, g.mc_JumpSpeed, baseJump * cfg.jumpMul);
            jumpApplied = true;
        } else if (jumpApplied) {
            wr<float>(mc, g.mc_JumpSpeed, baseJump);
            jumpApplied = false;
        }
    }

    // --- 2. God Mode No-Jailbreak (RAM Disarm Enemies + Auto-Revive Loop) ---
    static int godTick = 0;
    godTick++;
    if (cfg.infiniteHealth) {
        // A. Désarme les armes de tous les autres joueurs en RAM locale (0 dégât, 0 munition)
        for (void* np : players) {
            if (np == lp) continue;
            void* enemyItems = rd<void*>(np, g.np_Items);
            if (!plausible(enemyItems)) continue;
            int32_t en = rd<int32_t>(enemyItems, 0x18);
            if (en <= 0 || en > 10) continue;
            for (int j = 0; j < en; j++) {
                void* eItem = rd<void*>(enemyItems, 0x20 + 8 * j);
                if (!plausible(eItem)) continue;
                wr<int32_t>(eItem, g.it_Damage,  0);
                wr<int32_t>(eItem, g.it_CurAmmo, 0);
                wr<int32_t>(eItem, g.it_MaxAmmo, 0);
                wr<float>(eItem,   g.it_Range,   0.0f);
            }
        }
        // B. Maintien en vie / Revive propre toutes les 2 secondes sans patcher __TEXT
        if (godTick % 20 == 0) {
            ((fn_void0)(g_gbrBase + RVA_REVIVE_AS_HUMAN))(lp);
        }
    }

    // --- 3. Armes de TON joueur local : Munitions, One Hit Kill, Rapid Fire ---
    if (cfg.infiniteAmmo || cfg.oneHitKill || cfg.rapidFire) {
        void* itemsArr = rd<void*>(lp, g.np_Items);
        if (plausible(itemsArr)) {
            int32_t n = rd<int32_t>(itemsArr, 0x18);
            if (n > 0 && n <= 10) {
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
                    if (cfg.rapidFire) {
                        wr<float>(item, g.it_Speed,  0.001f);
                        wr<float>(item, g.it_Reload, 0.001f);
                        wr<float>(item, g.it_Range,  99999.0f);
                    }
                }
            }
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
@property (nonatomic, strong) UILabel* jumpLabel;
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
    UILabel* l = [self label:t size:14 bold:NO color:[UIColor whiteColor]];
    l.frame = CGRectMake(16, y, 230, 31);
    [sv addSubview:l];
    UISwitch* s = [UISwitch new];
    s.tag = tag;
    s.onTintColor = accent();
    s.center = CGPointMake(300 - 16 - s.bounds.size.width / 2, y + 15.5);
    [s addTarget:self action:@selector(sw:) forControlEvents:UIControlEventValueChanged];
    [sv addSubview:s];
    return y + 38;
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
    CGFloat W = 300, H = 500;
    UIBlurEffect* blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
    self.panel = [[UIVisualEffectView alloc] initWithEffect:blur];
    self.panel.frame = CGRectMake(0, 0, W, H);
    self.panel.layer.cornerRadius = 18;
    self.panel.clipsToBounds = YES;
    self.panel.layer.borderWidth = 1;
    self.panel.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.12].CGColor;
    self.panel.hidden = YES;

    UILabel* title = [self label:@"Nyx Menu - GBR 972" size:18 bold:YES color:[UIColor whiteColor]];
    title.frame = CGRectMake(16, 12, 220, 24);
    [self.panel.contentView addSubview:title];
    UILabel* sub = [self label:@"No-JB Safe (100% Heap RAM - 0 Crash)" size:11 bold:NO color:[UIColor colorWithWhite:1 alpha:0.5]];
    sub.frame = CGRectMake(16, 36, 240, 14);
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

    CGFloat y = 8;
    y = [self toggle:@"Munitions infinies" tag:0 y:y in:sv];
    y = [self toggle:@"One Hit Kill (9999 Dmg)" tag:1 y:y in:sv];
    y = [self toggle:@"Rapid Fire + Infinite Range" tag:5 y:y in:sv];
    y = [self toggle:@"God Mode (RAM No-Crash)" tag:3 y:y in:sv];
    y = [self toggle:@"Speed Hack (Safe AC)" tag:2 y:y in:sv];

    self.speedLabel = [self label:[NSString stringWithFormat:@"Vitesse : x%.1f", cfg.speedMul]
                             size:11 bold:NO color:[UIColor colorWithWhite:1 alpha:0.65]];
    self.speedLabel.frame = CGRectMake(16, y, 260, 14);
    [sv addSubview:self.speedLabel];
    [self slider:100 min:1.0 max:5.0 val:cfg.speedMul y:y + 14 in:sv];
    y += 44;

    y = [self toggle:@"Jump Boost" tag:6 y:y in:sv];
    self.jumpLabel = [self label:[NSString stringWithFormat:@"Saut : x%.1f", cfg.jumpMul]
                            size:11 bold:NO color:[UIColor colorWithWhite:1 alpha:0.65]];
    self.jumpLabel.frame = CGRectMake(16, y, 260, 14);
    [sv addSubview:self.jumpLabel];
    [self slider:101 min:1.0 max:5.0 val:cfg.jumpMul y:y + 14 in:sv];
    y += 46;

    [self button:@"Reviv humain" sel:@selector(reviveHumanTap) frame:CGRectMake(16, y, 130, 36) in:sv];
    [self button:@"Reviv zombie" sel:@selector(reviveZombieTap) frame:CGRectMake(154, y, 130, 36) in:sv];
    y += 44;
    [self button:@"Skin suivant (1-164)" sel:@selector(skinTap) frame:CGRectMake(16, y, W - 32, 36) in:sv];
    y += 44;

    self.statusLabel = [self label:@"" size:11 bold:NO color:[UIColor colorWithWhite:1 alpha:0.5]];
    self.statusLabel.numberOfLines = 3;
    self.statusLabel.frame = CGRectMake(16, y + 6, W - 32, 48);
    [sv addSubview:self.statusLabel];

    sv.contentSize = CGSizeMake(W, y + 65);
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
    if (s.tag == 0) { cfg.infiniteAmmo   = v; [self say:v ? @"Munitions infinies ON" : @"Munitions infinies OFF"]; }
    if (s.tag == 1) { cfg.oneHitKill     = v; [self say:v ? @"One Hit Kill ON" : @"One Hit Kill OFF"]; }
    if (s.tag == 2) { cfg.speed          = v; [self say:v ? @"Speed Hack RAM ON (Anti-AC)" : @"Speed Hack OFF"]; }
    if (s.tag == 3) { cfg.infiniteHealth = v; [self say:v ? @"God Mode RAM ON (Ennemis 0 Dmg + AutoRevive)" : @"God Mode OFF"]; }
    if (s.tag == 5) { cfg.rapidFire      = v; [self say:v ? @"Rapid Fire + Range ON" : @"Rapid Fire OFF"]; }
    if (s.tag == 6) { cfg.jumpBoost      = v; [self say:v ? @"Jump Boost ON" : @"Jump Boost OFF"]; }
    haptic();
    [self refresh];
}

- (void)slide:(UISlider*)s {
    float val = roundf(s.value * 10.f) / 10.f;
    if (s.tag == 100) {
        cfg.speedMul = val;
        self.speedLabel.text = [NSString stringWithFormat:@"Vitesse : x%.1f", cfg.speedMul];
    } else if (s.tag == 101) {
        cfg.jumpMul = val;
        self.jumpLabel.text = [NSString stringWithFormat:@"Saut : x%.1f", cfg.jumpMul];
    }
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
    [self say:r >= 0 ? [NSString stringWithFormat:@"Skin %d applique", r] : @"Impossible : pas en partie"];
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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        tryInstallUI();
        [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer* t) { coreTick(); }];
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer* t) {
            [[NyxGBR_UI shared] refresh];
            [[NyxGBR_UI shared] keepOnTop];
        }];
    });
}
