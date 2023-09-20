#ifndef CSTRING_H
#define CSTRING_H
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
// functions returning an int return 0 on failure and 1 on success

#define STRING_RETURN_IF_NULL(ptr) if(ptr == NULL) return STRING_ERROR
#define STRING_ERROR   0
#define STRING_SUCCESS 1

static const size_t string_npos = (const size_t)-1;// (~(size_t)0) one is left for the null term char
static const size_t _string_max_size = (const size_t)-2;

typedef struct
{
    size_t _null_char;
    size_t size;
    size_t capacity;
    char* data;
} _string;
typedef _string string[1];

// declarations
static inline int string_assign_c(string dest, size_t n, char c);

static inline size_t _min(size_t a, size_t b)
{
    return a < b ? a : b;
}

static inline void _string_set_props(string dest, size_t size, size_t capacity)
{
    dest->size = size;
    dest->capacity = capacity;
    dest->data[size] = 0;
    dest->_null_char = size;
}

static inline int _string_assign(string dest, const char* str, size_t str_len)
{
    if (str_len <= dest->capacity)
    {
        dest->size = str_len;
        memcpy(dest->data, str, str_len);
        dest->data[str_len] = 0;
        dest->_null_char = str_len;
        return STRING_SUCCESS;
    }

    dest->data = realloc(dest->data, str_len + 1);
    STRING_RETURN_IF_NULL(dest->data);
    _string_set_props(dest, str_len, str_len);
    memcpy(dest->data, str, dest->size);
    return STRING_SUCCESS;
}

static inline int _string_append(string dest, const char* src, size_t src_len)
{
    if (src_len == 0) return STRING_SUCCESS;

    const size_t min = _min(dest->size, dest->_null_char);
    const size_t new_len = min + src_len;
    if (dest->capacity >= new_len)
    {
        memcpy(&dest->data[min], src, src_len);
        dest->size = new_len;
        dest->data[dest->size] = 0;
        dest->_null_char = new_len;
        return STRING_SUCCESS;
    }

    dest->data = realloc(dest->data, new_len + 1);
    STRING_RETURN_IF_NULL(dest->data);
    memcpy(&dest->data[min], src, src_len);
    _string_set_props(dest, new_len, new_len);
    return STRING_SUCCESS;
}

static inline int _string_insert(string dest, size_t pos, const char* s, size_t n)
{
    if (pos >= dest->size) return STRING_ERROR;

    const size_t min = _min(dest->size, dest->_null_char);
    const size_t new_len = min + n;
    if (new_len <= dest->capacity)
    {
        memmove(&dest->data[pos + n], &dest->data[pos], dest->size - pos);
        memcpy(&dest->data[pos], s, n);
        dest->size = new_len;
        dest->_null_char = new_len;
        dest->data[dest->_null_char] = 0;
        return STRING_SUCCESS;
    }

    dest->data = realloc(dest->data, dest->size + n + 1);
    STRING_RETURN_IF_NULL(dest->data);
    memmove(&dest->data[pos + n], &dest->data[pos], dest->size - pos);
    memcpy(&dest->data[pos], s, n);
    _string_set_props(dest, new_len, new_len);
    return STRING_SUCCESS;
}

static inline size_t _string_find(const string dest, const char* str, size_t str_len, size_t pos)
{
    if (str_len == 0) return 0;
    if (str_len > dest->size) return string_npos;

    size_t off = pos;
    for (size_t i = off; i < dest->size; ++i)
    {
        if (dest->data[i] == str[0])
        {
            for (size_t k = 0; k < str_len && k + i < dest->size; ++k)
            {
                if (k == str_len - 1 && dest->data[k + i] == str[k])
                    return i;
                off = k;
            }
            i += off;
        }
    }
    return string_npos;
}

static inline size_t _string_rfind(const string dest, const char* str, size_t str_len, size_t pos)
{
    if (str_len == 0) return 0;
    if (str_len > dest->size || dest->size == 0 || pos >= dest->size) return string_npos;

    for (size_t i = pos; i != string_npos; --i)
    {
        if (dest->data[i] == str[0] && i + str_len <= dest->size && memcmp(&dest->data[i], str, str_len) == 0)
            return i;
    }
    return string_npos;
}

static inline size_t _string_find_first_of(const string dest, const char* str, size_t str_len, size_t pos)
{
    for (size_t i = pos; i < dest->size; ++i)
        for (size_t k = 0; k < str_len; ++k)
            if (dest->data[i] == str[k])
                return i;
    return string_npos;
}

static inline size_t _string_find_last_of(const string dest, const char* str, size_t str_len, size_t pos)
{
    if (pos < dest->size)
        for (size_t i = pos; i != string_npos; --i)
            for (size_t k = 0; k < str_len; ++k)
                if (dest->data[i] == str[k])
                    return i;
    return string_npos;
}

static inline size_t _string_find_first_not_of(const string dest, const char* str, size_t str_len, size_t pos)
{
    for (size_t i = pos; i < dest->size; ++i)
        for (size_t k = 0; k < str_len; ++k)
            if (dest->data[i] != str[k])
                return i;
    return string_npos;
}

static inline size_t _string_find_last_not_of(const string dest, const char* str, size_t str_len, size_t pos)
{
    if (pos < dest->size)
        for (size_t i = pos; i != string_npos; --i)
            for (size_t k = 0; k < str_len; ++k)
                if (dest->data[i] != str[k])
                    return i;
    return string_npos;
}

static inline void _string_reset(string s)
{
    s->_null_char = 0;
    s->size = 0;
    s->capacity = 0;
    s->data = NULL;
}

// public api
static inline void string_create_empty(string dest)
{
    _string_reset(dest);
}

static inline int string_create(string dest, const char* str)
{
    const size_t str_len = strlen(str);
    assert(str_len > 0 && "strlen(str) must be greater than 0 use string_create_empty for an empty string");
    _string_reset(dest);
    return _string_assign(dest, str, str_len);
}

static inline int string_create_s(string dest, const string src)
{
    assert(src->size > 0 && "strlen(str) must be greater than 0 use string_create_empty for an empty string");
    _string_reset(dest);
    return _string_assign(dest, src->data, src->size);
}

static inline int string_create_c(string dest, size_t n, char c)
{
    assert(n > 0 && "n must be greater than 0 use string_create_empty for an empty string");
    _string_reset(dest);
    return string_assign_c(dest, n, c);
}

static inline int string_create_r(string dest, const char* str, size_t n)
{
    assert(n > 0 && "n must be greater than 0 use string_create_empty for an empty string");
    _string_reset(dest);
    return _string_assign(dest, str, n);
}

static inline void string_free(string src)
{
    if (src->data != NULL)
        free(src->data);
    _string_reset(src);
}


static inline int string_assign(string s, const char* str)
{
    return _string_assign(s, str, strlen(str));
}

static inline int string_assign_s(string dest, const string src)
{
    return _string_assign(dest, src->data, src->size);
}

static inline int string_assign_r(string dest, const char* src, size_t n)
{
    return _string_assign(dest, src, n);
}

static inline int string_assign_c(string dest, size_t n, char c)
{
    if (n <= dest->capacity)
    {
        memset(dest->data, c, n);
        dest->size = n;
        dest->_null_char = n;
        dest->data[n] = 0;
        return STRING_SUCCESS;
    }

    dest->data = realloc(dest->data, n + 1);
    STRING_RETURN_IF_NULL(dest->data);
    memset(dest->data, c, n);
    _string_set_props(dest, n, n);
    if (c == 0) dest->_null_char = 0;
    return STRING_SUCCESS;
}

static inline int string_append(string dest, const char* src)
{
    return _string_append(dest, src, strlen(src));
}

static inline int string_append_s(string dest, const string src)
{
    return _string_append(dest, src->data, src->size);
}

static inline int string_append_r(string dest, const char* src, size_t n)
{
    return _string_append(dest, src, n);
}

static inline int string_append_c(string dest, size_t n, char c)
{
    const size_t min = _min(dest->size, dest->_null_char);
    const size_t new_len = min + n;
    if (new_len <= dest->capacity)
    {
        memset(&dest->data[min], c, n);
        dest->size = new_len;
        dest->_null_char = new_len;
        dest->data[new_len] = 0;
        return STRING_SUCCESS;
    }

    dest->data = realloc(dest->data, dest->size + n + 1);
    STRING_RETURN_IF_NULL(dest->data);
    memset(&dest->data[min], c, n);
    _string_set_props(dest, new_len, new_len);
    return STRING_SUCCESS;
}

static inline int string_insert_c(string dest, size_t pos, size_t n, char c)
{
    if (pos >= dest->size) return STRING_ERROR;

    const size_t min = _min(dest->size, dest->_null_char);
    const size_t new_len = min + n;
    if (new_len <= dest->capacity)
    {
        memmove(&dest->data[pos + n], &dest->data[pos], dest->size - pos);
        memset(&dest->data[pos], c, n);
        dest->size = new_len;
        dest->_null_char = new_len;
        dest->data[dest->_null_char] = 0;
        return STRING_SUCCESS;
    }

    dest->data = realloc(dest->data, dest->size + n + 1);
    STRING_RETURN_IF_NULL(dest->data);
    memmove(&dest->data[pos + n], &dest->data[pos], dest->size - pos);
    memset(&dest->data[pos], c, n);
    _string_set_props(dest, new_len, new_len);
    return STRING_SUCCESS;
}

static inline int string_insert(string dest, size_t pos, const char* s)
{
    return _string_insert(dest, pos, s, strlen(s));
}

static inline int string_insert_n(string dest, size_t pos, const char* s, size_t n)
{
    return _string_insert(dest, pos, s, n);
}

static inline int string_insert_s(string dest, size_t pos, const string str)
{
    return _string_insert(dest, pos, str->data, str->size);
}

static inline int string_insert_sub(string dest, size_t pos, const string str, size_t subpos, size_t sublen)
{
    if (subpos >= str->size || (sublen != string_npos && sublen > str->size)) return STRING_ERROR;
    return _string_insert(dest, pos, &str->data[subpos], sublen == string_npos ? str->size : sublen);
}

static inline int string_resize_c(string dest, size_t new_size, char c)
{
    if (new_size <= dest->capacity)
    {
        dest->size = new_size;
        dest->data[dest->size] = 0;
        dest->_null_char = new_size;
        return STRING_SUCCESS;
    }

    dest->data = realloc(dest->data, new_size + 1);
    STRING_RETURN_IF_NULL(dest->data);
    memset(&dest->data[dest->size], c, new_size - dest->size);
    if (c == 0)
        dest->_null_char = dest->size;
    else
        dest->_null_char = new_size;
    dest->size = new_size;
    dest->capacity = new_size;
    dest->data[dest->size] = 0;
    return STRING_SUCCESS;
}

static inline int string_resize(string dest, size_t new_size)
{
    return string_resize_c(dest, new_size, 0);
}

static inline int string_shrink_to_fit(string dest)
{
    if (dest->size == dest->capacity)
        return STRING_SUCCESS;

    dest->data = realloc(dest->data, dest->size + 1);
    STRING_RETURN_IF_NULL(dest->data);
    dest->capacity = dest->size;
    dest->_null_char = dest->size;
    return STRING_SUCCESS;
}

static inline int string_reserve(string dest, size_t n)
{
    if (n == dest->size) return STRING_SUCCESS;
    if (n < dest->size) return string_shrink_to_fit(dest);

    dest->data = realloc(dest->data, n + 1);
    STRING_RETURN_IF_NULL(dest->data);
    dest->capacity = n;
    memset(&dest->data[dest->size], 0, n - dest->size);
    return STRING_SUCCESS;
}

static inline int string_push_back(string dest, char c)
{
    return string_append_c(dest, 1, c);
}

static inline int string_pop_back(string dest)
{
    if (dest->size == 0) return STRING_ERROR;

    --dest->size;
    dest->data[dest->size] = 0;
    --dest->_null_char;
    return STRING_SUCCESS;
}

static inline void string_swap(string s1, string s2)
{
    _string tmp = { ._null_char = s1->_null_char, .size = s1->size, .capacity = s1->capacity, .data = s1->data };
    s1->_null_char = s2->_null_char;
    s1->capacity = s2->capacity;
    s1->size = s2->size;
    s1->data = s2->data;

    s2->_null_char = tmp._null_char;
    s2->capacity = tmp.capacity;
    s2->size = tmp.size;
    s2->data = tmp.data;
}

static inline void string_erase(string dest, size_t pos, size_t len)
{
    assert(pos < dest->size && "pos must be lest than string_size(dest)");

    if (len + pos >= dest->size)
    {
        dest->data[pos] = 0;
        dest->size = 0;
        dest->_null_char = 0;
        return;
    }

    memmove(&dest->data[pos], &dest->data[pos + len], dest->size - pos - len);
    dest->size -= len;
    dest->_null_char = dest->size;
    dest->data[dest->size] = 0;
}

static inline size_t string_copy(const string ss, char* s, size_t len, size_t pos)
{
    if (pos >= ss->size) return 0;
    const size_t to_copy = len + pos > ss->size ? ss->size - pos : len + pos;
    memcpy(s, &ss->data[pos], to_copy);
    return to_copy;
}

static inline int string_substr(const string s, string dest, size_t pos, size_t len)
{
    if (pos == s->size)
    {
        string_create_empty(dest);
        return STRING_SUCCESS;
    }
    else if (pos > s->size)
    {
        dest = NULL;
        return STRING_ERROR;
    }
    const size_t to_copy = len + pos > s->size ? s->size - pos : len + pos;
    string_create_r(dest, &s->data[pos], to_copy);
    return STRING_SUCCESS;
}

static inline size_t string_find_c(const string s, char c, size_t pos)
{
    for (size_t i = pos; i < s->size; ++i)
        if (s->data[i] == c) return i;
    return string_npos;
}

static inline size_t string_rfind_c(const string s, char c, size_t pos)
{
    if(s->size > 0 && pos < s->size)
        for (size_t i = pos; i != string_npos; --i)
            if (s->data[i] == c) return i;
    return string_npos;
}

static inline size_t string_find_first_of_c(const string s, char c, size_t pos)
{
    for (size_t i = pos; i < s->size; ++i)
        if (s->data[i] == c)
            return i;
    return string_npos;
}

static inline size_t string_find_last_of_c(const string s, char c, size_t pos)
{
    if (pos < s->size)
        for (size_t i = pos; i != string_npos; --i)
            if (s->data[i] == c)
                return i;
    return string_npos;
}

static inline size_t string_find_first_not_of_c(const string s, char c, size_t pos)
{
    for (size_t i = pos; i < s->size; ++i)
        if (s->data[i] != c)
            return i;
    return string_npos;
}

static inline size_t string_find_last_not_of_c(const string s, char c, size_t pos)
{
    if (pos < s->size)
        for (size_t i = pos; i != string_npos; --i)
            if (s->data[i] != c)
                return i;
    return string_npos;
}

static inline int string_compare(const string s, const char* str) { return strcmp(s->data, str) == 0; }
static inline int string_compare_s(const string s1, const string s2) { return strcmp(s1->data, s2->data) == 0; }
static inline size_t string_find(const string s, const char* str, size_t pos) { return _string_find(s, str, strlen(str), pos); }
static inline size_t string_find_s(const string s1, const string s2, size_t pos) { return _string_find(s1, s2->data, s2->size, pos); }
static inline size_t string_find_n(const string s, const char* str, size_t pos, size_t n) { return _string_find(s, str, n, pos); }
static inline size_t string_rfind(const string s, const char* str, size_t pos) { return _string_rfind(s, str, strlen(str), pos); }
static inline size_t string_rfind_s(const string s1, const string s2, size_t pos) { return _string_rfind(s1, s2->data, s2->size, pos); }
static inline size_t string_rfind_n(const string s, const char* str, size_t pos, size_t n) { return _string_rfind(s, str, n, pos); }
static inline size_t string_find_first_of(const string s, const char* str, size_t pos) { return _string_find_first_of(s, str, strlen(str), pos); }
static inline size_t string_find_first_of_s(const string s1, const string s2, size_t pos) { return _string_find_first_of(s1, s2->data, s2->size, pos); }
static inline size_t string_find_first_of_n(const string s, const char* str, size_t pos, size_t n) { return _string_find_first_of(s, str, n, pos); }
static inline size_t string_find_last_of(const string s, const char* str, size_t pos) { return _string_find_last_of(s, str, strlen(str), pos); }
static inline size_t string_find_last_of_s(const string s1, const string s2, size_t pos) { return _string_find_last_of(s1, s2->data, s2->size, pos); }
static inline size_t string_find_last_of_n(const string s, const char* str, size_t pos, size_t n) { return _string_find_last_of(s, str, n, pos); }
static inline size_t string_find_first_not_of(const string s, const char* str, size_t pos) { return _string_find_first_not_of(s, str, strlen(str), pos); }
static inline size_t string_find_first_not_of_s(const string s1, const string s2, size_t pos) { return _string_find_first_not_of(s1, s2->data, s2->size, pos); }
static inline size_t string_find_first_not_of_n(const string s, const char* str, size_t pos, size_t n) { return _string_find_first_not_of(s, str, n, pos); }
static inline size_t string_find_last_not_of(const string s, const char* str, size_t pos) { return _string_find_last_not_of(s, str, strlen(str), pos); }
static inline size_t string_find_last_not_of_s(const string s1, const string s2, size_t pos) { return _string_find_last_not_of(s1, s2->data, s2->size, pos); }
static inline size_t string_find_last_not_of_n(const string s, const char* str, size_t pos, size_t n) { return _string_find_last_not_of(s, str, n, pos); }

static inline int         string_empty(const string s) { return s->size == 0; }
static inline void        string_clear(string dest) { dest->size = 0; dest->data[0] = 0; dest->_null_char = 0; }
static inline char*       string_data(const string s) { return s->data; }
static inline const char* string_cstr(const string s) { return s->data; }
static inline size_t      string_max_size() { return _string_max_size; }
static inline size_t      string_size(const string s) { return s->size; }
static inline size_t      string_length(const string s) { return s->size; }
static inline size_t      string_capacity(const string s) { return s->capacity; }
static inline char        string_at(const string s, size_t idx) { return s->data[idx]; }
static inline char        string_front(const string s) { return s->data[0]; }
static inline char        string_back(const string s) { return s->data[s->size - 1]; }

static inline void string_print(const string s)
{
    printf("s: %zu c: %zu nc: %zu [%s]\n", s[0].size, s[0].capacity, s->_null_char, s[0].data);
    puts(s->data);
}
#undef STRING_RETURN_IF_NULL
#endif