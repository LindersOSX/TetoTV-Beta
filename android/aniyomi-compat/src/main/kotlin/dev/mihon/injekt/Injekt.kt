package dev.mihon.injekt

import uy.kohesive.injekt.Injekt
import uy.kohesive.injekt.api.InjektScope

@Suppress("UNUSED")
fun patchInjekt() {
    Injekt = InjektScope(PatchedDefaultRegister())
}
