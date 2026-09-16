// Android bridge adapted from Aniyomi 39e9a749590b89b432f04b83725aaa12591371b2.
// Apache-2.0; TetoTV modification removes KMP expect/actual only.
package eu.kanade.tachiyomi.util

import rx.Observable
import tachiyomi.core.common.util.lang.awaitSingle as awaitRuntimeSingle

suspend fun <T> Observable<T>.awaitSingle(): T = awaitRuntimeSingle()
