// Nyx Menu — Grand Battle Royale (iOS, Unity IL2CPP) — dump fourni par l'utilisateur
// Le jeu est protege par un obfuscateur de noms (Beebyte ou equivalent) : les champs et
// methodes internes du jeu sont renommes en charabia. Mais deux choses restent exploitables :
//   1. Les classes Item, NetworkPlayer, Game gardent leur vrai nom (verifie dans le dump).
//   2. Les methodes RPC Photon (ReceiveDamage, ReviveAsHuman, ...) gardent leur vrai nom,
//      parce que Photon doit pouvoir les appeler par leur nom exact sur le reseau.
// Les OFFSETS DE CHAMPS ont ete verifies et collent exactement entre le build Android
// (cf. OFF_NP_*/OFF_ITEM_* du mod LGL) et ce dump iOS : meme version Unity/IL2CPP,
// meme disposition memoire sur 64 bits. Les ADRESSES DE FONCTIONS codees en dur dans
// le mod Android (0xAB24FC, 0x150A910...) ne sont PAS reutilisees : ce sont des adresses
// de code natif, propres au binaire Android, inutilisables tel quel sur iOS.
//
// Build : clang++ -arch arm64 -fobjc-arc -dynamiclib (voir build.yml, identique a Among Us)

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdint.h>
#include <string.h>
#include <string>
#include <vector>
#include <mach-o/dyld.h>

// ============================ CORE BEGIN ============================

// L'API publique il2cpp_* a ete retiree du binaire a la publication (verifie en lisant
// le vrai fichier "gbr" : LC_SYMTAB existe mais ne contient que des symboles
// PLCrashReporter, aucun il2cpp_*). Inutile de la chercher par son nom.
// A la place, on appelle directement les fonctions du jeu par leur adresse, calculee
// comme (base de chargement de "gbr") + (RVA retrouvee dans dump_1.cs). La base de
// chargement se trouve via l'API publique dyld, qui ne depend d'aucun symbole du jeu.

typedef void* (*fn_getGameInstance)(void);   // getter statique Game.Instance, 0 argument

static uintptr_t g_gbrBase = 0;       // adresse de chargement de l'image "gbr" (ASLR deja applique)
static std::string g_lastMissingSymbol;

// RVA retrouvees dans dump_1.cs pour Grand Battle Royale 3.5.2.
// A revoir si le jeu est mis a jour (refaire le dump, rechercher la meme methode).
static const uintptr_t RVA_GAME_INSTANCE_GETTER = 0x19138DC;

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
    // le binaire principal du jeu s'appelle "gbr" (pas de UnityFramework separe) ;
    // son chemin dans le bundle est .../gbr.app/gbr
    g_gbrBase = FindImageBase("/gbr");
    if (!g_gbrBase) { g_lastMissingSymbol = "image gbr pas encore chargee"; return false; }
    return true;
}

struct Cfg {
    bool infiniteAmmo = false;
    bool oneHitKill = false;
};
static Cfg cfg;

static std::string g_status = "en attente du jeu...";

static struct {
    bool ready = false;
    void* f_gameInst = nullptr;   // pointeur Game.Instance, obtenu en appelant son getter
    // offsets de champs verifies (identiques entre le mod Android et ce dump iOS,
    // meme version Unity/IL2CPP, meme disposition memoire 64 bits) :
    int game_Players = 0x28;   // Game.players : List<NetworkPlayer>
    int np_Items     = 0x58;   // NetworkPlayer.items : Item[]
    int it_MaxAmmo   = 0x44;   // Item.maxAmo
    int it_CurAmmo   = 0x48;   // Item.currAmo
    int it_Damage    = 0x50;   // Item.itemDamage
} g;

template <typename T> static inline T rd(void* o, int off) { return *(T*)((uint8_t*)o + off); }
template <typename T> static inline void wr(void* o, int off, T v) { *(T*)((uint8_t*)o + off) = v; }

// Un pointeur "plausible" doit ressembler a une vraie adresse heap 64 bits : non nul et
// dans une plage raisonnable. Ca evite de dereferencer n'importe quoi si le getter
// renvoie une valeur qu'on n'attendait pas.
static inline bool plausible(void* p) {
    uintptr_t v = (uintptr_t)p;
    return v > 0x1000 && v < 0x7fffffffffffULL;
}

static bool initCore() {
    if (g.ready) return true;
    if (!loadAPI()) { g_status = "en attente : " + g_lastMissingSymbol; return false; }

    // Appel direct de Game.Instance via son adresse RVA. Pas d'API il2cpp, pas de
    // recherche de classe : juste un pointeur de fonction calcule a la main.
    fn_getGameInstance getInst = (fn_getGameInstance)(g_gbrBase + RVA_GAME_INSTANCE_GETTER);
    void* game = getInst();
    if (!plausible(game)) { g_status = "Game.Instance pas encore pret (relance au prochain essai)"; return false; }

    g.f_gameInst = game;
    g.ready = true;
    g_status = "connecte (appel direct par RVA, sans API il2cpp)";
    return true;
}

// Liste des NetworkPlayer de la partie en cours, via Game.Instance.players (List<NetworkPlayer>).
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

static void coreTick() {
    static int retry = 0;
    if (!g.ready) {
        if ((retry++ % 20) != 0) return;
        if (!initCore()) return;
    }
    if (!cfg.infiniteAmmo && !cfg.oneHitKill) return;

    for (void* np : playerObjs()) {
        void* itemsArr = rd<void*>(np, g.np_Items);
        if (!plausible(itemsArr)) continue;
        int32_t n = rd<int32_t>(itemsArr, 0x18);
        if (n <= 0 || n > 10) continue;
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
    CGFloat W = 300, H = 220;
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
    UILabel* sub = [self label:@"v3 - appel direct par RVA" size:11 bold:NO color:[UIColor colorWithWhite:1 alpha:0.5]];
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

    self.statusLabel = [self label:@"" size:11 bold:NO color:[UIColor colorWithWhite:1 alpha:0.5]];
    self.statusLabel.numberOfLines = 3;
    self.statusLabel.frame = CGRectMake(16, y + 10, W - 32, 50);
    [sv addSubview:self.statusLabel];

    sv.contentSize = CGSizeMake(W, y + 60);
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
    if (s.tag == 0) cfg.infiniteAmmo = v;
    if (s.tag == 1) cfg.oneHitKill = v;
    haptic();
}

- (void)refresh {
    if (self.panel.hidden) return;
    std::string st = g_status;
    self.statusLabel.text = [NSString stringWithFormat:@"%s", st.c_str()];
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
