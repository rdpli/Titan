cmake_minimum_required(VERSION 3.9)
project(Loch LANGUAGES CXX CUDA) # use CXX, CUDA by default (since CUDA is a language, don't need cuda_add_executable)

set(CMAKE_INSTALL_PREFIX ".")

set(CMAKE_MODULE_PATH ${CMAKE_MODULE_PATH} ${CMAKE_CURRENT_SOURCE_DIR}/cmake)

set(CMAKE_CXX_STANDARD 14) # set C++ standard to C++11
set(CUDA_NVCC_FLAGS "${CUDA_NVCC_FLAGS} -std=c++14") # same thing, may be unnecessary

set(SOURCE_DIR ${CMAKE_CURRENT_LIST_DIR}/src) # set SOURCE_DIR to src directory
set(INCLUDE_DIR ${CMAKE_CURRENT_LIST_DIR}/include) # set SOURCE_DIR to src directory

include_directories(include) # include the include directory (can find headers there)

set(SOURCE_FILES ${SOURCE_DIR}/vec.cu ${SOURCE_DIR}/sim.cu ${SOURCE_DIR}/sim.cu ${SOURCE_DIR}/mass.cu ${SOURCE_DIR}/spring.cu ${SOURCE_DIR}/object.cu ${SOURCE_DIR}/graphics.cpp ${SOURCE_DIR}/common/shader.cpp ${INCLUDE_DIR}/graphics.h ${INCLUDE_DIR}/mass.h ${INCLUDE_DIR}/object.h ${INCLUDE_DIR}/sim.h ${INCLUDE_DIR}/spring.h ${INCLUDE_DIR}/vec.h) # add all of the .cu/.cpp files to SOURCE_FILES target
file(GLOB HEADERS "${INCLUDE_DIR}/*.h")

find_package(CUDA REQUIRED) # find and include CUDA
if (CUDA_FOUND)
    message(STATUS "CUDA FOUND")
    include_directories(${CUDA_INCLUDE_DIRS})
    link_libraries(${CUDA_LIBRARIES})
else()
	message(STATUS "CUDA NOT FOUND")
endif()

find_package(OPENGL REQUIRED) # find and include OpenGL
if (OPENGL_FOUND)
    message(STATUS "OPENGL FOUND")
    include_directories(${OPENGL_INCLUDE_DIRS})
    link_libraries(${OPENGL_LIBRARIES})
endif()

if (WIN32)
    find_package(glfw3 CONFIG REQUIRED)
    if (glfw3_FOUND)
        message(STATUS "GLFW FOUND")
        include_directories(${glfw3_INCLUDE_DIRS})
        link_libraries(${glfw3_LIBRARIES})
    endif()
else()
    find_package(sdl2 CONFIG REQUIRED)
    if (sdl2_FOUND)
        message(STATUS "sdl2 FOUND")
        include_directories(${sdl2_INCLUDE_DIRS})
        link_libraries(${sdl2_LIBRARIES})
    endif()
endif()

find_package(GLEW REQUIRED) # GLEW
if (GLEW_FOUND)
    message(STATUS "GLEW FOUND")
    include_directories(${GLEW_INCLUDE_DIRS})
    link_libraries(${GLEW_LIBRARIES})
endif()

find_package(glm CONFIG REQUIRED) # glm
if (glm_FOUND)
    message(STATUS "GLM FOUND")
    include_directories(${glm_INCLUDE_DIRS})
    link_libraries(${glm_LIBRARIES})
endif()

file(COPY ${SOURCE_DIR}/shaders DESTINATION ${CMAKE_CURRENT_BINARY_DIR})
#
#add_library(nographics ${SOURCE_FILES} ${HEADERS}) # create nographics target
#target_compile_features(nographics PUBLIC cxx_std_11)
#set_target_properties(nographics PROPERTIES CUDA_SEPARABLE_COMPILATION ON) # allows declarations and implementations to be separated
#target_link_libraries(nographics PRIVATE cuda)
#target_compile_definitions(nographics PRIVATE CONSTRAINTS) # defines the CONSTRAINTS preprocessor variable (enables local constraints)

add_library(Loch ${SOURCE_FILES} ${HEADERS}) # create graphics target
target_compile_definitions(Loch PRIVATE GRAPHICS) # defines the GRAPHICS preprocessor variable
target_compile_definitions(Loch PRIVATE CONSTRAINTS) # defines the CONSTRAINTS preprocessor variable (enables local constraints)

target_compile_features(Loch PUBLIC cxx_std_11) # same as above
set_target_properties(Loch PROPERTIES CUDA_SEPARABLE_COMPILATION ON)
target_link_libraries(Loch PRIVATE cuda)

target_link_libraries(Loch PRIVATE glm)

if ( WIN32 ) # use GLFW on Windows
    target_link_libraries(Loch PRIVATE GLEW::GLEW)
    target_link_libraries(Loch PRIVATE glfw)
else() # use SDL2 on Mac
    target_link_libraries(Loch PRIVATE GLEW)
    target_link_libraries(Loch PRIVATE gl)
    target_link_libraries(Loch PRIVATE sdl2)
    target_compile_definitions(Loch PRIVATE SDL2)
endif()

set(Loch_INCLUDE_DIRS ${INCLUDE_DIR})
#set(Loch_LIBRARIES ${CMAKE_BINARY_DIR}/graphics.lib)

install(FILES ${HEADERS} DESTINATION include)
install(TARGETS Loch DESTINATION lib)
install(FILES LochConfig.cmake LochConfigVersion.cmake DESTINATION lib/cmake/LochConfig.cmake)