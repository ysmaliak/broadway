#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s SHELL FLAG COMMAND...\n", argv[0]);
        return 2;
    }
    int worst = 0;
    for (int index = 3; index < argc; index++) {
        pid_t child = fork();
        if (child == 0) {
            execl(argv[1], argv[1], argv[2], argv[index], (char *)NULL);
            _exit(127);
        }
        int status = 0;
        waitpid(child, &status, 0);
        int code = WIFEXITED(status) ? WEXITSTATUS(status) : 1;
        printf("exit %d\n", code);
        fflush(stdout);
        if (code > worst) worst = code;
    }
    return worst;
}
