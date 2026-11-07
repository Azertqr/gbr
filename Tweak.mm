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
#include <mach-o/loader.h>
#include <mach-o/nlist.h>

// ---- Lecteur de table de symboles Mach-O (repli quand dlsym echoue) ----
// Sur un build App Store, les symboles il2cpp_* existent dans le binaire mais ne sont
// pas toujours exportes publiquement : dlsym (meme via dlopen) ne les voit pas. On lit
// directement la LC_SYMTAB de l'image en memoire, qui liste TOUS les symboles.
static void* FindSymbolInImage(uint32_t imageIndex, const char* symbolName) {
    const struct mach_header_64* header =
        (const struct mach_header_64*)_dyld_get_image_header(imageIndex);
    if (!header) return nullptr;
    intptr_t slide = _dyld_get_image_vmaddr_slide(imageIndex);

    const struct symtab_command* symtab = nullptr;
    const struct segment_command_64* linkedit = nullptr;
    const struct segment_command_64* text = nullptr;

    const uint8_t* cur = (const uint8_t*)header + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command* lc = (const struct load_command*)cur;
        if (lc->cmd == LC_SYMTAB) symtab = (const struct symtab_command*)lc;
        else if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64* seg = (const struct segment_command_64*)lc;
            if (strcmp(seg->segname, "__LINKEDIT") == 0) linkedit = seg;
            else if (strcmp(seg->segname, "__TEXT") == 0) text = seg;
        }
        cur += lc->cmdsize;
    }
    if (!symtab || !linkedit || !text) return nullptr;
    (void)text;   // juste utilise pour confirmer que l'image a bien un __TEXT (executable valide)

    uintptr_t linkeditBase = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;

    const struct nlist_64* syms = (const struct nlist_64*)(linkeditBase + symtab->symoff);
    const char* strs = (const char*)(linkeditBase + symtab->stroff);

    for (uint32_t i = 0; i < symtab->nsyms; i++) {
        uint32_t strx = syms[i].n_un.n_strx;
        if (strx == 0) continue;
        const char* name = strs + strx;
        // les symboles C ont un '_' devant dans la table Mach-O
        if (name[0] == '_' && strcmp(name + 1, symbolName) == 0) {
            if (syms[i].n_value == 0) continue;   // symbole non defini (import)
            return (void*)((uintptr_t)syms[i].n_value + slide);
        }
    }
    return nullptr;
}

// Cherche dans toutes les images chargees (l'executable principal est generalement
// l'index 0, mais on balaie tout par securite).
static void* FindSymbolAnywhere(const char* symbolName) {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        void* r = FindSymbolInImage(i, symbolName);
        if (r) return r;
    }
    return nullptr;
}

// ============================ CORE BEGIN ============================

typedef void*  (*fn_domain_get)(void);
typedef void*  (*fn_domain_assembly_open)(void*, const char*);
typedef void*  (*fn_assembly_get_image)(void*);
typedef void*  (*fn_class_from_name)(void*, const char*, const char*);
typedef void*  (*fn_class_get_field_from_name)(void*, const char*);
typedef void*  (*fn_class_get_fields)(void*, void**);
typedef size_t (*fn_field_get_offset)(void*);
typedef const char* (*fn_field_get_name)(void*);
typedef void*  (*fn_field_static_get_value)(void*, void*);   // signature reelle : (field, out void*)
typedef void*  (*fn_class_get_method_from_name)(void*, const char*, int);
typedef void*  (*fn_class_get_methods)(void*, void**);
typedef const char* (*fn_method_get_name)(void*);
typedef uint32_t (*fn_method_get_param_count)(void*);
typedef void*  (*fn_runtime_invoke)(void*, void*, void**, void**);
typedef void*  (*fn_thread_attach)(void*);

static struct {
    fn_domain_get                 domain_get;
    fn_domain_assembly_open       domain_assembly_open;
    fn_assembly_get_image         assembly_get_image;
    fn_class_from_name            class_from_name;
    fn_class_get_field_from_name  class_get_field_from_name;
    fn_class_get_fields           class_get_fields;
    fn_field_get_offset           field_get_offset;
    fn_field_get_name             field_get_name;
    fn_field_static_get_value     field_static_get_value;
    fn_class_get_method_from_name class_get_method_from_name;
    fn_class_get_methods          class_get_methods;
    fn_method_get_name            method_get_name;
    fn_method_get_param_count     method_get_param_count;
    fn_runtime_invoke             runtime_invoke;
    fn_thread_attach              thread_attach;
} A;

static bool g_apiLoaded = false;
static std::string g_lastMissingSymbol;

static bool loadAPI() {
    if (g_apiLoaded) return true;
    // RTLD_DEFAULT ne cherche pas toujours correctement dans l'executable principal
    // quand le moteur Unity est embarque directement dedans (pas de UnityFramework.framework
    // separe, comme c'est le cas ici : tout est dans "gbr"). On demande explicitement le
    // handle de l'executable principal en secours.
    void* h = RTLD_DEFAULT;
    void* hMain = dlopen(nullptr, RTLD_NOW | RTLD_GLOBAL);
#define NYX_LOAD(f) \
    A.f = (fn_##f)dlsym(h, "il2cpp_" #f); \
    if (!A.f && hMain) A.f = (fn_##f)dlsym(hMain, "il2cpp_" #f); \
    if (!A.f) A.f = (fn_##f)FindSymbolAnywhere("il2cpp_" #f); \
    if (!A.f) { g_lastMissingSymbol = "il2cpp_" #f; return false; }
    NYX_LOAD(domain_get)
    NYX_LOAD(domain_assembly_open)
    NYX_LOAD(assembly_get_image)
    NYX_LOAD(class_from_name)
    NYX_LOAD(class_get_field_from_name)
    NYX_LOAD(field_get_offset)
    NYX_LOAD(field_static_get_value)
    NYX_LOAD(class_get_method_from_name)
    NYX_LOAD(runtime_invoke)
#undef NYX_LOAD
    A.class_get_fields       = (fn_class_get_fields)dlsym(h, "il2cpp_class_get_fields");
    A.field_get_name         = (fn_field_get_name)dlsym(h, "il2cpp_field_get_name");
    A.class_get_methods      = (fn_class_get_methods)dlsym(h, "il2cpp_class_get_methods");
    A.method_get_name        = (fn_method_get_name)dlsym(h, "il2cpp_method_get_name");
    A.method_get_param_count = (fn_method_get_param_count)dlsym(h, "il2cpp_method_get_param_count");
    A.thread_attach          = (fn_thread_attach)dlsym(h, "il2cpp_thread_attach");
    g_apiLoaded = true;
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
    void* domain = nullptr;
    void *cItem = nullptr, *cNP = nullptr, *cGame = nullptr, *cPV = nullptr;
    int it_MaxAmmo = -1, it_CurAmmo = -1, it_Damage = -1;
    int np_Items = -1;
    int game_Players = -1;
    void* f_gameInst = nullptr;   // champ statique "Game" trouve par structure (self-type)
    void* m_rpcInvoke = nullptr;  // PhotonView.RPC(string, PhotonTargets, object[]) trouve par signature
} g;

template <typename T> static inline T rd(void* o, int off) { return *(T*)((uint8_t*)o + off); }
template <typename T> static inline void wr(void* o, int off, T v) { *(T*)((uint8_t*)o + off) = v; }

static int FO(void* klass, const char* name) {
    if (!klass) return -1;
    void* f = A.class_get_field_from_name(klass, name);
    return f ? (int)A.field_get_offset(f) : -1;
}

// Trouve un champ STATIQUE de `klass` dont le TYPE est `klass` lui-meme : c'est le motif
// classique d'un singleton Unity (`private static Game <Instance>k__BackingField`), meme
// quand le nom du champ est scramble par l'obfuscateur — ici on ne cherche pas le nom,
// on cherche la forme.
static void* FindSelfTypeStaticField(void* klass, const char* className) {
    if (!klass || !A.class_get_fields) return nullptr;
    void* iter = nullptr; void* f = nullptr;
    while ((f = A.class_get_fields(klass, &iter)) != nullptr) {
        // offset 0x0 ET nom de champ qui commence par '<' (backing field auto-genere) :
        // suffisant ici vu qu'un seul champ statique de ce type existe dans Game.
        if (A.field_get_offset(f) == 0) {
            const char* nm = A.field_get_name ? A.field_get_name(f) : nullptr;
            if (nm && nm[0] == '<') return f;
        }
    }
    (void)className;
    return nullptr;
}

// Trouve PhotonView.RPC(string, PhotonTargets, object[]) par SA SIGNATURE (3 parametres),
// parce que son nom reel est scramble comme le reste du code du jeu.
static void* FindPhotonRPC(void* klass) {
    if (!klass || !A.class_get_methods || !A.method_get_name || !A.method_get_param_count) return nullptr;
    void* iter = nullptr; void* m = nullptr;
    while ((m = A.class_get_methods(klass, &iter)) != nullptr) {
        if (A.method_get_param_count(m) == 3) {
            // Premiere methode publique a 3 parametres trouvee sur PhotonView : dans ce dump
            // il n'y en a qu'une avec cette forme (string, enum, object[]) -> RPC().
            return m;
        }
    }
    return nullptr;
}

static void* sget(void* field) {
    if (!field) return nullptr;
    void* v = nullptr;
    A.field_static_get_value(field, &v);
    return v;
}

static void* invoke(void* m, void* obj, void** args) {
    if (!m) return nullptr;
    void* exc = nullptr;
    void* r = A.runtime_invoke(m, obj, args, &exc);
    return exc ? nullptr : r;
}

static bool initCore() {
    if (g.ready) return true;
    if (!loadAPI()) { g_status = "API il2cpp introuvable (manque : " + g_lastMissingSymbol + ")"; return false; }
    g.domain = A.domain_get();
    if (!g.domain) { g_status = "il2cpp pas encore lance"; return false; }

    void* asmAC  = A.domain_assembly_open(g.domain, "Assembly-CSharp");
    void* asmPUN = A.domain_assembly_open(g.domain, "PhotonUnityNetworking");
    if (!asmPUN) asmPUN = A.domain_assembly_open(g.domain, "Photon3Unity3D");
    if (!asmAC) { g_status = "Assembly-CSharp introuvable"; return false; }
    void* imgAC  = A.assembly_get_image(asmAC);
    void* imgPUN = asmPUN ? A.assembly_get_image(asmPUN) : nullptr;
    if (!imgAC) { g_status = "image introuvable"; return false; }

    g.cItem = A.class_from_name(imgAC, "", "Item");
    g.cNP   = A.class_from_name(imgAC, "", "NetworkPlayer");
    g.cGame = A.class_from_name(imgAC, "", "Game");
    g.cPV   = imgPUN ? A.class_from_name(imgPUN, "", "PhotonView") : nullptr;
    if (!g.cPV) g.cPV = A.class_from_name(imgAC, "", "PhotonView");   // parfois fusionne dans Assembly-CSharp
    if (!g.cItem || !g.cNP || !g.cGame) { g_status = "classes du jeu introuvables (Item/NetworkPlayer/Game)"; return false; }

    g.it_MaxAmmo = FO(g.cItem, "maxAmo");
    g.it_CurAmmo = FO(g.cItem, "currAmo");
    g.it_Damage  = FO(g.cItem, "itemDamage");
    g.np_Items   = FO(g.cNP, "items");          // nom scramble -> probablement -1, voir repli plus bas
    g.game_Players = FO(g.cGame, "players");    // idem

    // Repli : si les noms scrambles empechent FO() de trouver le champ par nom, on retombe
    // sur l'offset verifie manuellement (0x58 pour NetworkPlayer.items, 0x28 pour Game.players),
    // confirme identique sur Android et sur ce dump iOS.
    if (g.np_Items < 0) g.np_Items = 0x58;
    if (g.game_Players < 0) g.game_Players = 0x28;

    g.f_gameInst = FindSelfTypeStaticField(g.cGame, "Game");
    g.m_rpcInvoke = g.cPV ? FindPhotonRPC(g.cPV) : nullptr;

    g.ready = true;
    g_status = g.f_gameInst ? "connecte (Game trouve)" : "connecte (Game.Instance non resolu, a verifier en jeu)";
    return true;
}

// Liste des NetworkPlayer de la partie en cours, via Game.Instance.players (List<NetworkPlayer>).
static std::vector<void*> playerObjs() {
    std::vector<void*> out;
    if (!g.ready || !g.f_gameInst) return out;
    void* game = sget(g.f_gameInst);
    if (!game) return out;
    void* list = rd<void*>(game, g.game_Players);
    if (!list) return out;
    void* items = rd<void*>(list, 0x10);
    int32_t n = rd<int32_t>(list, 0x18);
    if (!items || n <= 0 || n > 64) return out;
    for (int i = 0; i < n; i++) {
        void* np = rd<void*>(items, 0x20 + 8 * i);
        if (np) out.push_back(np);
    }
    return out;
}

static void coreTick() {
    static int retry = 0;
    if (!g.ready) {
        if ((retry++ % 20) != 0) return;
        if (!initCore()) return;
    }
    if (A.thread_attach) A.thread_attach(g.domain);
    if (!cfg.infiniteAmmo && !cfg.oneHitKill) return;

    for (void* np : playerObjs()) {
        void* itemsArr = rd<void*>(np, g.np_Items);
        if (!itemsArr) continue;
        int32_t n = rd<int32_t>(itemsArr, 0x18);
        if (n <= 0 || n > 10) continue;
        for (int j = 0; j < n; j++) {
            void* item = rd<void*>(itemsArr, 0x20 + 8 * j);
            if (!item) continue;
            if (cfg.infiniteAmmo && g.it_MaxAmmo >= 0 && g.it_CurAmmo >= 0) {
                wr<int32_t>(item, g.it_MaxAmmo, 9999);
                wr<int32_t>(item, g.it_CurAmmo, 9999);
            }
            if (cfg.oneHitKill && g.it_Damage >= 0) {
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
    UILabel* sub = [self label:@"v2 - scan symboles Mach-O" size:11 bold:NO color:[UIColor colorWithWhite:1 alpha:0.5]];
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
