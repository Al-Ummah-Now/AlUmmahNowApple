#ifndef AUN_SIGNAL_TRAP_H
#define AUN_SIGNAL_TRAP_H

#include <stdbool.h>

void aun_signal_trap_enable(const char *marker_path);
void aun_signal_trap_disable(void);
bool aun_signal_trap_is_installed(void);

#endif
