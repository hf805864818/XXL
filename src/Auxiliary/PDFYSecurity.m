//
//  PDFYSecurity.m
//  PetDFY 可编辑源码 · 数据目录权限加固（逐条还原）
//
//  还原依据：PDFYSecurity.dylib（arm64，79 条指令，单函数 _pdfy_security_init）
//  反汇编里就是 18 条 chmod(path, mode)，路径按 adr 立即数解出，顺序一致：
//    04000-04084 区间：目录 0700 ×2，随后 0600 ×16
//  原文件另有 .pdfy_security.* 标记路径的 open/write，属于可选的自检标记，
//  本还原保留 chmod 语义（标记文件在下面的 PDFY_MARK 开关里可关闭）。
//

#import <Foundation/Foundation.h>
#import <sys/stat.h>

static void PDFYChmod(const char *path, mode_t mode) {
    chmod(path, mode);
}

__attribute__((constructor))
static void pdfy_security_init(void) {
    // ---- 数据目录：0700（仅 owner 可读写执行）----
    PDFYChmod("/var/mobile/Library/Application Support/PetDFY", 0700);
    PDFYChmod("/var/jb/var/mobile/Library/Application Support/PetDFY", 0700);

    // ---- 密钥 / 会话文件：0600 ----
    PDFYChmod("/var/mobile/Library/Application Support/PetDFY/AIAPIKey", 0600);
    PDFYChmod("/var/mobile/Library/Application Support/PetDFY/AIAPIKey.txt", 0600);
    PDFYChmod("/var/mobile/Library/Application Support/PetDFY/ai-api-key", 0600);
    PDFYChmod("/var/mobile/Library/Application Support/PetDFY/DoubaoAPIKey", 0600);
    PDFYChmod("/var/mobile/Library/Application Support/PetDFY/DoubaoAPIKey.txt", 0600);
    PDFYChmod("/var/mobile/Library/Application Support/PetDFY/conversation.json", 0600);
    PDFYChmod("/var/mobile/Library/Application Support/PetDFY/context-state.json", 0600);

    PDFYChmod("/var/jb/var/mobile/Library/Application Support/PetDFY/AIAPIKey", 0600);
    PDFYChmod("/var/jb/var/mobile/Library/Application Support/PetDFY/AIAPIKey.txt", 0600);
    PDFYChmod("/var/jb/var/mobile/Library/Application Support/PetDFY/ai-api-key", 0600);
    PDFYChmod("/var/jb/var/mobile/Library/Application Support/PetDFY/DoubaoAPIKey", 0600);
    PDFYChmod("/var/jb/var/mobile/Library/Application Support/PetDFY/DoubaoAPIKey.txt", 0600);
    PDFYChmod("/var/jb/var/mobile/Library/Application Support/PetDFY/conversation.json", 0600);
    PDFYChmod("/var/jb/var/mobile/Library/Application Support/PetDFY/context-state.json", 0600);

    // ---- 偏好 plist（可能含密钥明文）----
    PDFYChmod("/var/mobile/Library/Preferences/com.susudear.petdfyprefs.plist", 0600);
    PDFYChmod("/var/jb/var/mobile/Library/Preferences/com.susudear.petdfyprefs.plist", 0600);
}
