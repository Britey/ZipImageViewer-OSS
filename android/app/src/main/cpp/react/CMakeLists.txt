# Separate source directory prevents RN from treating codec JNI files as its OnLoad.cpp.
set(CMAKE_CXX_STANDARD 20)
include(${REACT_ANDROID_DIR}/cmake-utils/ReactNative-application.cmake)
