#ifndef PROGRESS_BAR_H
#define PROGRESS_BAR_H

#ifdef __cplusplus
    #include <cstdio>
    #include <cstddef>
    #include <cstring>
    #define STD std::
    using sizet = std::size_t;
#else
    #include <stdio.h>
    #include <stddef.h>
    #include <string.h>
    #define STD
    typedef size_t sizet;
#endif

#define PROGRESS_BAR_SIZE 31 // 31: msys2 default
#define PROGRESS_BAR_REAL_SIZE (PROGRESS_BAR_SIZE + 3)

typedef struct
{
    char* bar;
    sizet size;
} ProgressBarS;


static ProgressBarS* ProgressBarGet()
{
    static char bar[PROGRESS_BAR_REAL_SIZE];
    static ProgressBarS pBar = { bar, 0 };
    return &pBar;
}


static void ProgressBarInit()
{
    ProgressBarS* pBar = ProgressBarGet();
    pBar->size = 0;
    char* bar = pBar->bar;
    bar[0] = '[';
    bar[PROGRESS_BAR_REAL_SIZE - 2] = ']';
    bar[PROGRESS_BAR_REAL_SIZE - 1] = '\0';
    for (sizet i = 1; i < PROGRESS_BAR_REAL_SIZE - 2; ++i)
        bar[i] = '-';
}


static void ProgressBarAdd(sizet blocks)
{
    ProgressBarS* pBar = ProgressBarGet();
    blocks = blocks - pBar->size;
    for (sizet i = 1; i < PROGRESS_BAR_SIZE + 1; ++i)
    {
        if (pBar->bar[i] == '-')
        {
            if (i + blocks > (PROGRESS_BAR_SIZE + 1))
                blocks = PROGRESS_BAR_SIZE - pBar->size;
            STD memset((void*)&pBar->bar[i], '#', blocks * sizeof(char));
            pBar->size += blocks;
            return;
        }
    }
}


static void ProgressBar(float current, float hundred)
{
    const float percentDone = (current / hundred) * 100.f;
    const sizet newBlocksToAdd = (sizet)(percentDone * PROGRESS_BAR_SIZE / 100);
    ProgressBarAdd(newBlocksToAdd);

    STD printf("%s %.2f%% (%zu|%zu)\r", ProgressBarGet()->bar, percentDone, (sizet)current, (sizet)hundred);
    if (percentDone == 100.f)
        STD putchar('\n');
}
#endif
