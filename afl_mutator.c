#include <stdio.h>
#include <stdlib.h>
typedef struct afl_state_t afl_state_t;

typedef uint8_t u8;

void __untracer_mutate(u8 *mem, int position)
{
    mem[position >> 3] ^= (128 >> (position & 7));
}

typedef struct my_mutator
{

    afl_state_t *afl;
    uint32_t pos;
    size_t nbits;
    size_t max_size;
    u8 *buf;
    size_t buf_size;

} my_mutator_t;

void *afl_custom_init(afl_state_t *afl, unsigned int seed)
{
    (void)seed;
    my_mutator_t *m = calloc(1, sizeof(*m));
    if (!m)
        return NULL;
    m->afl = afl;
    m->buf_size = 1 << 20;
    m->buf = malloc(m->buf_size);
    if (!m->buf)
    {
        free(m);
        return NULL;
    }
    return m;
}

unsigned int afl_custom_fuzz_count(my_mutator_t *m, const unsigned char *buf, size_t buf_size)
{
    (void)buf;
    m->pos = 0;
    m->nbits = (buf_size << 3);
    return m->nbits;
}

size_t afl_custom_fuzz(my_mutator_t *m, unsigned char *buf, size_t buf_size, unsigned char **out_buf, unsigned char *add_buf, size_t add_buf_size, size_t max_size)
{
    (void)add_buf;
    (void)add_buf_size;
    if (m->buf_size < buf_size)
    {
        void *nbuf = realloc(m->buf, buf_size);
        if (nbuf == NULL)
        {
            return 0;
        }
        m->buf = nbuf;
        m->buf_size = buf_size;
        m->nbits = (buf_size << 3);
    }
    uint32_t pos = m->pos;
    if (pos++ >= m->nbits)
        return 0;

    memcpy(m->buf, buf, buf_size);
    __untracer_mutate(m->buf, (int)m->pos++);

    *out_buf = m->buf;
    return buf_size;
}
void afl_custom_deinit(my_mutator_t *m)
{
    free(m->buf);
    free(m);
}