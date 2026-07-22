-- C source for doomgeneric_maki.c, the maki backend for ozkl/doomgeneric.
-- Frames: scale to MAKI_DOOM_W x MAKI_DOOM_H (nearest by default, box
-- filter when MAKI_DOOM_FILTER=smooth), raw BGRA plus a trailing u32 frame
-- counter, written to $MAKI_DOOM_DIR/frame.tmp then atomically renamed to
-- frame.bin.
-- Keys: polls $MAKI_DOOM_DIR/keys ("<seq> <doomkey>\n" lines), presses new
-- seqs, auto-releases each key 150ms later.
return [[
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "doomgeneric.h"

#define MAX_HELD 32
#define QUEUE_LEN 64
#define RELEASE_MS 150

static char frame_tmp[512];
static char frame_bin[512];
static char keys_path[512];
static int out_w, out_h;
static int smooth;
static uint32_t *out_buf;

static unsigned long last_seq;
static struct { unsigned char key; uint32_t release_at; } held[MAX_HELD];
static int held_count;

static struct { int pressed; unsigned char key; } queue[QUEUE_LEN];
static int q_head, q_len;

uint32_t DG_GetTicksMs(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint32_t)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}

void DG_SleepMs(uint32_t ms) { usleep(ms * 1000); }

void DG_SetWindowTitle(const char *title) { (void)title; }

void DG_Init() {
  const char *dir = getenv("MAKI_DOOM_DIR");
  const char *w = getenv("MAKI_DOOM_W");
  const char *h = getenv("MAKI_DOOM_H");
  if (!dir || !w || !h) {
    fprintf(stderr, "maki-doom: MAKI_DOOM_DIR/W/H env vars required\n");
    exit(1);
  }
  out_w = atoi(w);
  out_h = atoi(h);
  if (out_w <= 0 || out_h <= 0 || strlen(dir) > 400) {
    fprintf(stderr, "maki-doom: bad MAKI_DOOM_DIR/W/H\n");
    exit(1);
  }
  snprintf(frame_tmp, sizeof frame_tmp, "%s/frame.tmp", dir);
  snprintf(frame_bin, sizeof frame_bin, "%s/frame.bin", dir);
  snprintf(keys_path, sizeof keys_path, "%s/keys", dir);
  const char *filter = getenv("MAKI_DOOM_FILTER");
  smooth = filter && strcmp(filter, "smooth") == 0;
  out_buf = malloc((size_t)out_w * out_h * 4);
  if (!out_buf) {
    fprintf(stderr, "maki-doom: out of memory\n");
    exit(1);
  }
}

static void scale_nearest(void) {
  for (int y = 0; y < out_h; y++) {
    const uint32_t *src = DG_ScreenBuffer + (size_t)(y * DOOMGENERIC_RESY / out_h) * DOOMGENERIC_RESX;
    uint32_t *dst = out_buf + (size_t)y * out_w;
    for (int x = 0; x < out_w; x++)
      dst[x] = src[x * DOOMGENERIC_RESX / out_w];
  }
}

static void scale_box(void) {
  for (int y = 0; y < out_h; y++) {
    int sy0 = y * DOOMGENERIC_RESY / out_h;
    int sy1 = (y + 1) * DOOMGENERIC_RESY / out_h;
    if (sy1 <= sy0) sy1 = sy0 + 1;
    uint32_t *dst = out_buf + (size_t)y * out_w;
    for (int x = 0; x < out_w; x++) {
      int sx0 = x * DOOMGENERIC_RESX / out_w;
      int sx1 = (x + 1) * DOOMGENERIC_RESX / out_w;
      if (sx1 <= sx0) sx1 = sx0 + 1;
      uint32_t r = 0, g = 0, b = 0, n = 0;
      for (int sy = sy0; sy < sy1; sy++) {
        const uint32_t *src = DG_ScreenBuffer + (size_t)sy * DOOMGENERIC_RESX;
        for (int sx = sx0; sx < sx1; sx++) {
          uint32_t p = src[sx];
          r += (p >> 16) & 0xff;
          g += (p >> 8) & 0xff;
          b += p & 0xff;
          n++;
        }
      }
      dst[x] = ((r / n) << 16) | ((g / n) << 8) | (b / n);
    }
  }
}

void DG_DrawFrame() {
  static uint32_t frame_seq;
  if (smooth)
    scale_box();
  else
    scale_nearest();
  frame_seq++;
  FILE *f = fopen(frame_tmp, "wb");
  if (!f) return;
  fwrite(out_buf, 4, (size_t)out_w * out_h, f);
  fwrite(&frame_seq, 4, 1, f);
  fclose(f);
  rename(frame_tmp, frame_bin);
}

static void push_event(int pressed, unsigned char key) {
  if (q_len == QUEUE_LEN) return;
  int tail = (q_head + q_len) % QUEUE_LEN;
  queue[tail].pressed = pressed;
  queue[tail].key = key;
  q_len++;
}

static void hold_key(unsigned char key, uint32_t now) {
  for (int i = 0; i < held_count; i++) {
    if (held[i].key == key) {
      held[i].release_at = now + RELEASE_MS;
      return;
    }
  }
  if (held_count < MAX_HELD) {
    held[held_count].key = key;
    held[held_count].release_at = now + RELEASE_MS;
    held_count++;
  }
}

static void poll_keys(void) {
  uint32_t now = DG_GetTicksMs();
  FILE *f = fopen(keys_path, "r");
  if (f) {
    char line[64];
    while (fgets(line, sizeof line, f)) {
      unsigned long seq;
      unsigned int key;
      if (!strchr(line, '\n')) continue;
      if (sscanf(line, "%lu %u", &seq, &key) != 2 || key > 255) continue;
      if (seq <= last_seq) continue;
      last_seq = seq;
      push_event(1, (unsigned char)key);
      hold_key((unsigned char)key, now);
    }
    fclose(f);
  }
  for (int i = 0; i < held_count;) {
    if ((int32_t)(now - held[i].release_at) >= 0) {
      push_event(0, held[i].key);
      held[i] = held[--held_count];
    } else {
      i++;
    }
  }
}

int DG_GetKey(int *pressed, unsigned char *doomKey) {
  if (q_len == 0) poll_keys();
  if (q_len == 0) return 0;
  *pressed = queue[q_head].pressed;
  *doomKey = queue[q_head].key;
  q_head = (q_head + 1) % QUEUE_LEN;
  q_len--;
  return 1;
}

int main(int argc, char **argv) {
  doomgeneric_Create(argc, argv);
  for (;;) doomgeneric_Tick();
  return 0;
}
]]
