#include <jni.h>
#include "NitroUnzipOnLoad.hpp"

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void*) {
  return margelo::nitro::unzip::initialize(vm);
}
