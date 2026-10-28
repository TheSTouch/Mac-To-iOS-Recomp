// Unity ports: a log that can be read after the fact. On iOS the game's own log (Unity's
// Debug.Log, printed to stdout) and anything on stderr go nowhere once the app runs on its
// own, so this tees both into Library/Logs/recomp.log in the app container; the previous
// launch's log is kept as recomp.log.1. Each stream goes through a pipe whose reader thread
// writes to the original descriptor (a devicectl --console stream still sees everything) and
// to the file, a whole line at a time with the time in front. Writes go straight to the
// file, so a crash keeps every line read before it.
//
// RecompLog_Line puts a line in the file only, for the native code that logs to os_log
// (RecompSteam_Log, the license check): a second os_log or stderr line would show twice.
// Unity ports get this file in Assets/Plugins/iOS with the other top-level files of
// recomp/native.
//
// Read it from the Mac with
//   xcrun devicectl device copy from --device <id> --domain-type appDataContainer
//       --domain-identifier <bundle id> --source Library/Logs/recomp.log --destination <dir>
#import <Foundation/Foundation.h>
#include <fcntl.h>
#include <os/lock.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/uio.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

static int gFile = -1;
static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static bool gMirrored;   // os_log also reaches stderr (Xcode, devicectl --console)

// "HH:MM:SS.mmm " in local time.
static size_t Stamp(char *out, size_t size)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    struct tm tm;
    localtime_r(&tv.tv_sec, &tm);
    return (size_t)snprintf(out, size, "%02d:%02d:%02d.%03d ", tm.tm_hour, tm.tm_min, tm.tm_sec, (int)(tv.tv_usec / 1000));
}

// One line, stamped; text holds no newline of its own (the caller's is replaced).
static void WriteLine(const char *text, size_t length)
{
    if (gFile < 0)
        return;
    char stamp[32];
    size_t n = Stamp(stamp, sizeof stamp);
    struct iovec v[3] = {{stamp, n}, {(void *)text, length}, {"\n", 1}};
    os_unfair_lock_lock(&gLock);
    writev(gFile, v, 3);
    os_unfair_lock_unlock(&gLock);
}

void RecompLog_Line(const char *line)
{
    if (!gMirrored && line)
        WriteLine(line, strlen(line));
}

typedef struct { int pipe, original; } Tee;

static void *TeeThread(void *arg)
{
    Tee tee = *(Tee *)arg;
    free(arg);
    pthread_setname_np("recomp.log");
    char buf[8192];
    size_t used = 0;
    for (;;)
    {
        ssize_t n = read(tee.pipe, buf + used, sizeof buf - used);
        if (n <= 0)
            break;
        if (tee.original >= 0)
            write(tee.original, buf + used, (size_t)n);
        used += (size_t)n;
        size_t start = 0;
        for (size_t i = 0; i < used; i++)
            if (buf[i] == '\n')
            {
                WriteLine(buf + start, i - start);
                start = i + 1;
            }
        if (start == 0 && used == sizeof buf)  // a line longer than the buffer: write what we have
        {
            WriteLine(buf, used);
            used = 0;
        }
        else
        {
            memmove(buf, buf + start, used - start);
            used -= start;
        }
    }
    return NULL;
}

static void TeeDescriptor(int fd)
{
    int p[2];
    if (pipe(p) != 0)
        return;
    Tee *tee = malloc(sizeof *tee);
    tee->pipe = p[0];
    tee->original = dup(fd);
    dup2(p[1], fd);
    close(p[1]);
    pthread_t thread;
    if (pthread_create(&thread, NULL, TeeThread, tee) == 0)
        pthread_detach(thread);
}

__attribute__((constructor)) static void RecompLogInstall(void)
{
    @autoreleasepool {
        NSString *dir = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject
                         stringByAppendingPathComponent:@"Logs"];
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
        NSString *path = [dir stringByAppendingPathComponent:@"recomp.log"];
        rename(path.fileSystemRepresentation, [path stringByAppendingString:@".1"].fileSystemRepresentation);
        gFile = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND | O_CLOEXEC, 0644);
        if (gFile < 0)
            return;
    }
    gMirrored = getenv("OS_ACTIVITY_DT_MODE") != NULL;
    // stdout into a pipe would be fully buffered: a line would wait for 4 KB behind it.
    setvbuf(stdout, NULL, _IOLBF, 0);
    TeeDescriptor(STDOUT_FILENO);
    TeeDescriptor(STDERR_FILENO);
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    char line[256];
    snprintf(line, sizeof line, "[recomp] log: %s %s, %s",
             [info[@"CFBundleName"] UTF8String] ?: "?", [info[@"CFBundleShortVersionString"] UTF8String] ?: "?",
             NSProcessInfo.processInfo.operatingSystemVersionString.UTF8String);
    WriteLine(line, strlen(line));
}
