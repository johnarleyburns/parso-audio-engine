#include "parso_dsp.h"
#include "parso_engine.h"

int main(void) {
    pe_control control = {0};
    pe_command command = {0};
    pe_stats stats = {0};
    (void)control;
    (void)command;
    (void)stats;
    return PD_OK == 0 && PE_MAX_DECKS >= 2 ? 0 : 1;
}
