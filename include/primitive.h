#ifdef SIMULATION
#define PRIMITIVE INLINEABLE
#define PRIMITIVE_I INLINE
#else
#define PRIMITIVE NOINLINE
#define PRIMITIVE_I NOINLINE
#endif