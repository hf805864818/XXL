//
//  PDHairTintPanel.m
//  PetDFY 可编辑源码 · 长发色面板
//

#import "PDHairTintPanel.h"
#import "PDHairTint.h"
#import <QuartzCore/QuartzCore.h>

NSString * const PDHairTintDidChangeNotification = @"PDHairTintDidChangeNotification";

static NSString * const kPDHairDomain = @"com.susudear.petdfyprefs";

static void PDHairWrite(NSString *key, id value) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFTypeRef)value,
                             (__bridge CFStringRef)kPDHairDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kPDHairDomain);
}

#pragma mark - 行工厂

@interface PDHairPanelRow : UIView
@property (nonatomic, strong) UILabel *title;
@property (nonatomic, strong) UILabel *value;
@property (nonatomic, strong) UISlider *slider;
- (instancetype)initWithTitle:(NSString *)title
                          min:(float)min
                          max:(float)max
                        value:(float)value
                       format:(NSString *(^)(float))format;
@end

@implementation PDHairPanelRow
- (instancetype)initWithTitle:(NSString *)title
                          min:(float)min
                          max:(float)max
                        value:(float)value
                       format:(NSString *(^)(float))format {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;

    _title = [[UILabel alloc] init];
    _title.text = title;
    _title.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    _title.textColor = [UIColor colorWithWhite:0.85 alpha:1.0];

    _value = [[UILabel alloc] init];
    _value.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
    _value.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];
    _value.textAlignment = NSTextAlignmentRight;

    _slider = [[UISlider alloc] init];
    _slider.minimumValue = min;
    _slider.maximumValue = max;
    _slider.value = value;

    UIStackView *top = [[UIStackView alloc] initWithArrangedSubviews:@[ _title, _value ]];
    top.axis = UILayoutConstraintAxisHorizontal;
    top.distribution = UIStackViewDistributionFill;
    top.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *col = [[UIStackView alloc] initWithArrangedSubviews:@[ top, _slider ]];
    col.axis = UILayoutConstraintAxisVertical;
    col.spacing = 2;
    col.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:col];

    [NSLayoutConstraint activateConstraints:@[
        [col.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [col.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [col.topAnchor constraintEqualToAnchor:self.topAnchor],
        [col.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ]];

    _slider.continuous = YES;
    (void)format;
    return self;
}
@end

#pragma mark - 面板

@interface PDHairTintPanel ()
@property (nonatomic, strong) UISwitch *enableSwitch;
@property (nonatomic, strong) UISegmentedControl *modeSegment;
@property (nonatomic, strong) UIStackView *swatchStack;
@property (nonatomic, strong) PDHairPanelRow *hueRow;
@property (nonatomic, strong) PDHairPanelRow *satRow;
@property (nonatomic, strong) PDHairPanelRow *valRow;
@property (nonatomic, strong) PDHairPanelRow *strRow;
@property (nonatomic, strong) NSMutableArray<UIButton *> *swatches;
@end

@implementation PDHairTintPanel

static PDHairTintPanel *gPanel = nil;

+ (void)presentInWindow:(UIWindow *)window {
    if (gPanel) { [self dismiss]; }
    UIWindow *w = window;
    if (!w) {
        for (UIWindow *cand in [UIApplication sharedApplication].windows) {
            if (cand.isKeyWindow) { w = cand; break; }
        }
    }
    if (!w) w = [UIApplication sharedApplication].windows.firstObject;
    if (!w) return;

    PDHairTintPanel *p = [[PDHairTintPanel alloc] initWithFrame:CGRectMake(0, 0, 320, 452)];
    p.center = CGPointMake(CGRectGetMidX(w.bounds), CGRectGetMidY(w.bounds));
    p.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                         UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    p.tag = 0x50444854; // 'PDHT'
    [w addSubview:p];
    gPanel = p;

    p.transform = CGAffineTransformMakeScale(0.92, 0.92);
    p.alpha = 0;
    [UIView animateWithDuration:0.18 animations:^{
        p.transform = CGAffineTransformIdentity;
        p.alpha = 1;
    }];
}

+ (void)dismiss {
    PDHairTintPanel *p = gPanel;
    if (!p) return;
    gPanel = nil;
    [UIView animateWithDuration:0.15 animations:^{
        p.alpha = 0;
        p.transform = CGAffineTransformMakeScale(0.94, 0.94);
    } completion:^(BOOL done) {
        [p removeFromSuperview];
    }];
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.97];
    self.layer.cornerRadius = 18;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.borderWidth = 1.0 / [UIScreen mainScreen].scale;
    self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.12].CGColor;
    self.layer.shadowColor = [UIColor blackColor].CGColor;
    self.layer.shadowOpacity = 0.4;
    self.layer.shadowRadius = 20;
    self.layer.shadowOffset = CGSizeMake(0, 8);

    _swatches = [NSMutableArray array];
    [self buildUI];
    [self syncFromSettings];
    return self;
}

#pragma mark - UI

- (UILabel *)caption:(NSString *)text size:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color {
    UILabel *l = [[UILabel alloc] init];
    l.text = text;
    l.font = [UIFont systemFontOfSize:size weight:weight];
    l.textColor = color;
    return l;
}

- (UIButton *)roundButton:(NSString *)title action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (UIStackView *)rowWith:(NSArray<UIView *> *)views spacing:(CGFloat)spacing {
    UIStackView *s = [[UIStackView alloc] initWithArrangedSubviews:views];
    s.axis = UILayoutConstraintAxisHorizontal;
    s.spacing = spacing;
    s.alignment = UIStackViewAlignmentCenter;
    return s;
}

- (void)buildUI {
    UIStackView *col = [[UIStackView alloc] init];
    col.axis = UILayoutConstraintAxisVertical;
    col.spacing = 12;
    col.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:col];
    [NSLayoutConstraint activateConstraints:@[
        [col.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [col.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
        [col.topAnchor constraintEqualToAnchor:self.topAnchor constant:16],
    ]];

    // 标题行
    UILabel *title = [self caption:@"发色" size:17 weight:UIFontWeightBold
                              color:[UIColor whiteColor]];
    UILabel *sub = [self caption:@"HSV 重着色 · 保留明暗与线稿" size:11 weight:UIFontWeightRegular
                           color:[UIColor colorWithWhite:0.6 alpha:1.0]];
    UIStackView *titleCol = [[UIStackView alloc] initWithArrangedSubviews:@[ title, sub ]];
    titleCol.axis = UILayoutConstraintAxisVertical;
    titleCol.spacing = 1;

    UIButton *close = [self roundButton:@"✕" action:@selector(onClose)];
    close.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
    [close.widthAnchor constraintEqualToConstant:32].active = YES;
    [close.heightAnchor constraintEqualToConstant:32].active = YES;

    UIView *spacer = [[UIView alloc] init];
    [spacer setContentHuggingPriority:1 forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *head = [self rowWith:@[ titleCol, spacer, close ] spacing:8];
    [col addArrangedSubview:head];

    // 启用开关
    UILabel *enableLabel = [self caption:@"启用发色" size:14 weight:UIFontWeightMedium
                                   color:[UIColor colorWithWhite:0.9 alpha:1.0]];
    UIView *spacer2 = [[UIView alloc] init];
    [spacer2 setContentHuggingPriority:1 forAxis:UILayoutConstraintAxisHorizontal];
    _enableSwitch = [[UISwitch alloc] init];
    _enableSwitch.onTintColor = [UIColor colorWithRed:0.36 green:0.78 blue:0.98 alpha:1];
    [_enableSwitch addTarget:self action:@selector(onAnyControl) forControlEvents:UIControlEventValueChanged];
    [col addArrangedSubview:[self rowWith:@[ enableLabel, spacer2, _enableSwitch ] spacing:8]];

    // 模式
    _modeSegment = [[UISegmentedControl alloc] initWithItems:@[ @"预设", @"自定", @"彩虹" ]];
    [_modeSegment addTarget:self action:@selector(onAnyControl) forControlEvents:UIControlEventValueChanged];
    [col addArrangedSubview:_modeSegment];

    // 色板
    UILabel *swTitle = [self caption:@"预设色板" size:12 weight:UIFontWeightMedium
                                color:[UIColor colorWithWhite:0.75 alpha:1.0]];
    [col addArrangedSubview:swTitle];

    _swatchStack = [[UIStackView alloc] init];
    _swatchStack.axis = UILayoutConstraintAxisHorizontal;
    _swatchStack.spacing = 8;
    _swatchStack.distribution = UIStackViewDistributionFillEqually;
    NSArray *presets = [[[PDHairTint presets] allKeys] sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *name in presets) {
        NSString *hex = [PDHairTint presets][name];
        UIColor *c = [PDHairTint colorFromHex:hex] ?: [UIColor whiteColor];
        UIButton *sw = [UIButton buttonWithType:UIButtonTypeCustom];
        sw.backgroundColor = c;
        sw.layer.cornerRadius = 11;
        sw.layer.borderWidth = 1.0 / [UIScreen mainScreen].scale;
        sw.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.25].CGColor;
        sw.accessibilityIdentifier = name;
        [sw addTarget:self action:@selector(onSwatch:) forControlEvents:UIControlEventTouchUpInside];
        [sw.heightAnchor constraintEqualToConstant:22].active = YES;
        [_swatchStack addArrangedSubview:sw];
        [_swatches addObject:sw];
    }
    [col addArrangedSubview:_swatchStack];

    // 四个滑杆
    _hueRow = [[PDHairPanelRow alloc] initWithTitle:@"色相 H" min:0 max:360 value:330 format:nil];
    _satRow = [[PDHairPanelRow alloc] initWithTitle:@"饱和度 S" min:0 max:100 value:55 format:nil];
    _valRow = [[PDHairPanelRow alloc] initWithTitle:@"明度 V" min:40 max:160 value:100 format:nil];
    _strRow = [[PDHairPanelRow alloc] initWithTitle:@"混合强度" min:0 max:100 value:100 format:nil];
    for (PDHairPanelRow *r in @[ _hueRow, _satRow, _valRow, _strRow ]) {
        [r.slider addTarget:self action:@selector(onAnyControl) forControlEvents:UIControlEventValueChanged];
        [col addArrangedSubview:r];
    }

    // 底部按钮
    UIButton *apply = [UIButton buttonWithType:UIButtonTypeSystem];
    [apply setTitle:@"应用" forState:UIControlStateNormal];
    apply.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    apply.backgroundColor = [UIColor colorWithRed:0.36 green:0.78 blue:0.98 alpha:1];
    [apply setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    apply.layer.cornerRadius = 11;
    [apply.heightAnchor constraintEqualToConstant:38].active = YES;
    [apply addTarget:self action:@selector(onApply) forControlEvents:UIControlEventTouchUpInside];

    UIButton *reset = [UIButton buttonWithType:UIButtonTypeSystem];
    [reset setTitle:@"关闭发色" forState:UIControlStateNormal];
    reset.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    reset.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    [reset setTitleColor:[UIColor colorWithWhite:0.85 alpha:1] forState:UIControlStateNormal];
    reset.layer.cornerRadius = 11;
    [reset.heightAnchor constraintEqualToConstant:38].active = YES;
    [reset addTarget:self action:@selector(onReset) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *actions = [[UIStackView alloc] initWithArrangedSubviews:@[ reset, apply ]];
    actions.axis = UILayoutConstraintAxisHorizontal;
    actions.spacing = 10;
    actions.distribution = UIStackViewDistributionFillEqually;
    [col addArrangedSubview:actions];
}

#pragma mark - 同步与提交

- (void)syncFromSettings {
    PDHairTint *h = [PDHairTint shared];
    _enableSwitch.on = h.enabled;
    switch (h.mode) {
        case PDHairTintModeCustom:  _modeSegment.selectedSegmentIndex = 1; break;
        case PDHairTintModeRainbow: _modeSegment.selectedSegmentIndex = 2; break;
        default:                    _modeSegment.selectedSegmentIndex = 0; break;
    }
    _hueRow.slider.value = (float)h.hue;
    _satRow.slider.value = (float)(h.saturation * 100.0);
    _valRow.slider.value = (float)(h.value * 100.0);
    _strRow.slider.value = (float)(h.strength * 100.0);
    [self updateValueLabels];
    [self highlightSwatch:h.presetName];
}

- (void)updateValueLabels {
    _hueRow.value.text = [NSString stringWithFormat:@"%d°", (int)lrintf(_hueRow.slider.value)];
    _satRow.value.text = [NSString stringWithFormat:@"%d%%", (int)lrintf(_satRow.slider.value)];
    _valRow.value.text = [NSString stringWithFormat:@"%d%%", (int)lrintf(_valRow.slider.value)];
    _strRow.value.text = [NSString stringWithFormat:@"%d%%", (int)lrintf(_strRow.slider.value)];
}

- (void)highlightSwatch:(NSString *)name {
    for (UIButton *b in _swatches) {
        BOOL on = [b.accessibilityIdentifier isEqualToString:name];
        b.transform = on ? CGAffineTransformMakeScale(1.18, 1.18) : CGAffineTransformIdentity;
        b.layer.borderColor = (on ? [UIColor whiteColor] : [UIColor colorWithWhite:1 alpha:0.25]).CGColor;
        b.layer.borderWidth = on ? 2.0 : 1.0 / [UIScreen mainScreen].scale;
    }
}

- (void)commit {
    BOOL on = _enableSwitch.on;
    NSString *mode = @"preset";
    switch (_modeSegment.selectedSegmentIndex) {
        case 1: mode = @"custom"; break;
        case 2: mode = @"rainbow"; break;
        default: mode = @"preset"; break;
    }
    PDHairWrite(@"HairTint", @(on));
    PDHairWrite(@"HairTintMode", mode);
    PDHairWrite(@"HairHue", @(_hueRow.slider.value));
    PDHairWrite(@"HairSat", @(_satRow.slider.value));
    PDHairWrite(@"HairValue", @(_valRow.slider.value));
    PDHairWrite(@"HairTintStrength", @(_strRow.slider.value));

    [[PDHairTint shared] reload];
    [[NSNotificationCenter defaultCenter] postNotificationName:PDHairTintDidChangeNotification
                                                        object:self];
}

#pragma mark - 事件

- (void)onAnyControl {
    [self updateValueLabels];
    // 滑杆拖动时先预写强度/明度，保证手感即时
    if (!_enableSwitch.on) return;
    PDHairWrite(@"HairHue", @(_hueRow.slider.value));
    PDHairWrite(@"HairSat", @(_satRow.slider.value));
    PDHairWrite(@"HairValue", @(_valRow.slider.value));
    PDHairWrite(@"HairTintStrength", @(_strRow.slider.value));
    [[PDHairTint shared] reload];
    [[NSNotificationCenter defaultCenter] postNotificationName:PDHairTintDidChangeNotification
                                                        object:self];
}

- (void)onSwatch:(UIButton *)sender {
    NSString *name = sender.accessibilityIdentifier;
    PDHairWrite(@"HairTintPreset", name);
    NSString *hex = [PDHairTint presets][name];
    UIColor *c = [PDHairTint colorFromHex:hex];
    // 预设同时把滑杆对齐到该色，避免「选了色板但滑杆没动」的割裂感
    if (c) {
        CGFloat r = 0, g = 0, b = 0, a = 1;
        if ([c getRed:&r green:&g blue:&b alpha:&a]) {
            CGFloat hh, ss, vv;
            UIColor *hsvColor = [UIColor colorWithRed:r green:g blue:b alpha:1];
            [hsvColor getHue:&hh saturation:&ss brightness:&vv alpha:NULL];
            _hueRow.slider.value = (float)(hh * 360.0);
            _satRow.slider.value = (float)(ss * 100.0);
            _valRow.slider.value = (float)(MAX(0.4, vv) * 100.0);
        }
    }
    _enableSwitch.on = YES;
    _modeSegment.selectedSegmentIndex = 0;
    [self updateValueLabels];
    [self highlightSwatch:name];
    [self commit];
}

- (void)onApply {
    [self commit];
    [self updateValueLabels];
    UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [fb impactOccurred];
}

- (void)onReset {
    _enableSwitch.on = NO;
    [self commit];
    [PDHairTintPanel dismiss];
}

- (void)onClose {
    [PDHairTintPanel dismiss];
}

@end
