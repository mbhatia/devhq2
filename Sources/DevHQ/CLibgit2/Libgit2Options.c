#include "CLibgit2.h"

int devhq_git_libgit2_set_extensions(const char **extensions, size_t length)
{
    return git_libgit2_opts(GIT_OPT_SET_EXTENSIONS, extensions, length);
}
