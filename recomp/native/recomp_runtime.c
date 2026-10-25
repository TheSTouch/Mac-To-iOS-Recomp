// Native start-up fixes compiled into every Unity port (copied to Assets/Plugins/iOS).
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>

// Desktop games keep user data under Environment.SpecialFolder.MyDocuments, which
// .NET resolves to $HOME. On iOS $HOME is the sandbox root, where apps cannot
// create folders, so point it at Documents (visible in the Files app). iOS's own
// APIs locate the sandbox through CFFIXED_USER_HOME, which is pinned first.
__attribute__((constructor)) static void recomp_home_to_documents(void)
{
    const char *container = getenv("CFFIXED_USER_HOME");
    if (!container) container = getenv("HOME");
    if (!container) return;
    char docs[1024];
    if (snprintf(docs, sizeof docs, "%s/Documents", container) >= (int)sizeof docs) return;
    mkdir(docs, 0755);
    setenv("CFFIXED_USER_HOME", container, 0);
    setenv("HOME", docs, 1);
}
