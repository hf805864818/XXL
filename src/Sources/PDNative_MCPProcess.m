//
//  PDNative_MCPProcess.m
//  补齐逆向稿里只有 extern、没有实现的进程/路径辅助函数。
//  这些符号如果缺失，PetDFY.dylib 在 dyld 绑定阶段会失败，表现就是被 ellekit 静默跳过。
//

#import <Foundation/Foundation.h>
#import <spawn.h>
#import <sys/wait.h>
#import <unistd.h>
#import <fcntl.h>
#import <errno.h>

extern char **environ;

static NSString *PDMCPFindJailbreakRoot(void) {
    const char *envRoot = getenv("JB_ROOT_PATH");
    if (envRoot && envRoot[0]) return [NSString stringWithUTF8String:envRoot];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *apps = [fm contentsOfDirectoryAtPath:@"/var/containers/Bundle/Application" error:NULL];
    for (NSString *name in apps) {
        if (![name hasPrefix:@".jbroot-"]) continue;
        NSString *root = [@"/var/containers/Bundle/Application" stringByAppendingPathComponent:name];
        if ([fm fileExistsAtPath:[root stringByAppendingPathComponent:@"Library"]]) return root;
    }
    if ([fm fileExistsAtPath:@"/var/jb/Library"]) return @"/var/jb";
    return nil;
}

NSString *PDNative_MCPResolvedJailbreakPath(NSString *path) {
    if (![path isKindOfClass:[NSString class]] || path.length == 0) return path;
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:path]) return path;
    NSString *root = PDMCPFindJailbreakRoot();
    if (!root) return path;
    NSString *candidate = [root stringByAppendingPathComponent:path];
    return [fm fileExistsAtPath:candidate] ? candidate : path;
}

BOOL PDNative_MCPRunProcess(NSString *tool,
                            NSArray *arguments,
                            NSDictionary *environment,
                            NSUInteger flags,
                            NSString **output,
                            int *exitCode,
                            NSError **error) {
    (void)environment; (void)flags;
    if (![tool isKindOfClass:[NSString class]] || tool.length == 0) {
        if (error) *error = [NSError errorWithDomain:@"PDNative_MCPProcess" code:-1
                                            userInfo:@{NSLocalizedDescriptionKey: @"empty tool path"}];
        return NO;
    }
    NSString *resolved = PDNative_MCPResolvedJailbreakPath(tool);
    NSMutableArray *argv = [NSMutableArray arrayWithObject:resolved];
    if ([arguments isKindOfClass:[NSArray class]]) {
        for (id arg in arguments) [argv addObject:[arg description]];
    }
    char **cargv = calloc(argv.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < argv.count; i++) cargv[i] = (char *)[argv[i] UTF8String];

    int pfd[2] = {-1, -1};
    if (pipe(pfd) != 0) {
        free(cargv);
        if (error) *error = [NSError errorWithDomain:@"PDNative_MCPProcess" code:errno userInfo:nil];
        return NO;
    }
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, pfd[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, pfd[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, pfd[0]);
    posix_spawn_file_actions_addclose(&actions, pfd[1]);

    pid_t pid = 0;
    int rc = posix_spawn(&pid, [resolved fileSystemRepresentation], &actions, NULL, cargv, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(pfd[1]);
    free(cargv);
    if (rc != 0) {
        close(pfd[0]);
        if (error) *error = [NSError errorWithDomain:@"PDNative_MCPProcess" code:rc
                                            userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"posix_spawn failed: %s", strerror(rc)]}];
        return NO;
    }

    NSMutableData *buffer = [NSMutableData data];
    char chunk[4096];
    ssize_t got = 0;
    while ((got = read(pfd[0], chunk, sizeof(chunk))) > 0) {
        [buffer appendBytes:chunk length:(NSUInteger)got];
    }
    close(pfd[0]);

    int status = 0;
    waitpid(pid, &status, 0);
    if (output) {
        *output = [[NSString alloc] initWithData:buffer encoding:NSUTF8StringEncoding] ?: @"";
    }
    if (exitCode) {
        *exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    }
    return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}
