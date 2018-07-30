//
// Created by Jacob Austin on 5/17/18.
//

#include "sim.h"

#include <thrust/remove.h>
#include <thrust/execution_policy.h>

#ifdef GRAPHICS
#include <GLFW/glfw3.h>
#endif

#include <cuda_runtime.h>
#include <cuda.h>
#include <cuda_device_runtime_api.h>
#include <cuda_gl_interop.h>

#ifdef GRAPHICS
#ifndef SDL2
void framebuffer_size_callback(GLFWwindow* window, int width, int height);
#endif
#endif

__global__ void createSpringPointers(CUDA_SPRING ** ptrs, CUDA_SPRING * data, int size);
__global__ void createMassPointers(CUDA_MASS ** ptrs, CUDA_MASS * data, int size);

__global__ void computeSpringForces(CUDA_SPRING * device_springs, int num_springs);
//__global__ void computeMassForces(CUDA_MASS * device_masses, int num_masses);
__global__ void massForcesAndUpdate(CUDA_SPRING * device_springs, Constraint ** d_constraints, int num_springs, int num_constraints);
//__global__ void update(CUDA_MASS * d_mass, int num_masses);



__device__ const double G = 9.81;

bool Simulation::RUNNING;
bool Simulation::STARTED;
bool Simulation::ENDED;
bool Simulation::FREED;

#ifdef GRAPHICS
GLFWwindow * Simulation::window;
GLuint Simulation::VertexArrayID;
GLuint Simulation::programID;
GLuint Simulation::MatrixID;
glm::mat4 Simulation::MVP;
GLuint Simulation::vertices;
GLuint Simulation::colors;
GLuint Simulation::indices;
bool Simulation::update_indices;
bool Simulation::update_colors;
int Simulation::lineWidth;
int Simulation::pointSize;
bool Simulation::resize_buffers;
#endif

#define gpuErrchk(ans) { gpuAssert((ans), __FILE__, __LINE__); }
inline void gpuAssert(cudaError_t code, const char *file, int line, bool abort=false)
{
    if (code != cudaSuccess)
    {
        fprintf(stderr,"GPUassert: %s %s %d\n", cudaGetErrorString(code), file, line);
        if (abort) exit(code);
    }
}

//__global__ void freeMasses(CUDA_MASS ** ptr, int size) {
//    int i = blockDim.x * blockIdx.x + threadIdx.x;
//
//    if (i < size) {
//        free(ptr[i]);
//    }
//}
//
//__global__ void freeSprings(CUDA_SPRING ** ptr, int size) {
//    int i = blockDim.x * blockIdx.x + threadIdx.x;
//
//    if (i < size) {
//        if (ptr[i] -> _left && ! (ptr[i] -> _left -> valid)) {
//                free(ptr[i] -> _left);
//        }
//
//        if (ptr[i] -> _right && ! (ptr[i] -> _right -> valid)) {
//            free(ptr[i] -> _right);
//        }
//
//        free(ptr[i]);
//    }
//}

Simulation::Simulation() {
    dt = 0;
    RUNNING = false;
    STARTED = false;
    ENDED = false;
    FREED = false;

    update_constraints = true;

#ifdef GRAPHICS
    resize_buffers = true;
    update_colors = true;
    update_indices = true;

    lineWidth = 1;
    pointSize = 3;
#endif
}

void Simulation::freeGPU() {
    std::cout << "Freeing GPU and CPU resources." << std::endl;

    for (Spring * s : springs) {
        if (s -> _left && ! s -> _left -> valid) {
            if (s -> _left -> arrayptr) {
                gpuErrchk(cudaFree(s -> _left -> arrayptr));
            }

            delete s -> _left;
        }

        if (s -> _right && ! s -> _right -> valid) {
            if (s -> _right -> arrayptr) {
                gpuErrchk(cudaFree(s -> _right -> arrayptr));
            }

            delete s -> _right;
        }

        delete s;
    }

    for (Mass * m : masses) {
        delete m;
    }

    for (Constraint * c : constraints)  {
        delete c;
    }

    for (Container * c : objs) {
        delete c;
    }

    d_balls.clear();
    d_balls.shrink_to_fit();

    d_planes.clear();
    d_planes.shrink_to_fit();

//    freeSprings<<<springBlocksPerGrid, THREADS_PER_BLOCK>>>(d_spring, springs.size()); // MUST COME BEFORE freeMasses
//    freeMasses<<<massBlocksPerGrid, THREADS_PER_BLOCK>>>(d_mass, masses.size());

#ifdef GRAPHICS
    glDeleteBuffers(1, &vertices);
    glDeleteBuffers(1, &colors);
    glDeleteBuffers(1, &indices);
    glDeleteProgram(programID);
    glDeleteVertexArrays(1, &VertexArrayID);

//     Close OpenGL window and terminate GLFW
#ifdef SDL2
    SDL_GL_DeleteContext(context);
    SDL_DestroyWindow(window);

    SDL_Quit();
#else
    glfwTerminate();
#endif
#endif

    FREED = true;
    ENDED = true; // just to be safe

    std::cout << "All memory successfully freed!" << std::endl;
}

Simulation::~Simulation() {
    std::cerr << "Simulation destructor called." << std::endl;

    while (RUNNING) {
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }

    if (gpu_thread.joinable()) {
        gpu_thread.join();
    } else {
        std::cout << "could not join GPU thread." << std::endl;
    }

    ENDED = true; // TODO maybe race condition
    freeGPU();

    FREED = true;

    std::cout << "Simulation destructor done." << std::endl;
}

Mass * Simulation::createMass(Mass * m) {
    if (ENDED) {
        std::cerr << "simulation has ended." << std::endl;
        exit(1);
    }

    m -> ref_count++;

    if (!STARTED) {
        masses.push_back(m);
        return m;
    } else {
        if (RUNNING) {
            std::cerr << "simulation is running. stop the simulation make changes" << std::endl;
            exit(1);
        }

        masses.push_back(m);

        CUDA_MASS * d_mass;
        gpuErrchk(cudaMalloc((void **) &d_mass, sizeof(CUDA_MASS)));
        m -> arrayptr = d_mass;

        d_masses.push_back(d_mass);

        CUDA_MASS temp = CUDA_MASS(*m);
        gpuErrchk(cudaMemcpy(d_mass, &temp, sizeof(CUDA_MASS), cudaMemcpyHostToDevice));
#ifdef GRAPHICS
        resize_buffers = true;
#endif
        return m;
    }
}

Spring * Simulation::getSpringByIndex(int i) {
    assert(i < springs.size() && i >= 0);

    return springs[i];
}

Mass * Simulation::getMassByIndex(int i) {
    assert(i < masses.size() && i >= 0);

    return masses[i];
}

Container * Simulation::getContainerByIndex(int i) {
    assert(i < objs.size() && i >= 0);

    return objs[i];
}

Mass * Simulation::createMass() {
    if (ENDED) {
        std::cerr << "simulation has ended." << std::endl;
        exit(1);
    }

    Mass * m = new Mass();
    return createMass(m);
}

Mass * Simulation::createMass(const Vec & pos) {
    if (ENDED) {
        std::cerr << "simulation has ended." << std::endl;
        exit(1);
    }

    Mass * m = new Mass(pos);
    return createMass(m);
}

Spring * Simulation::createSpring(Spring * s) {
    if (ENDED) {
        std::cerr << "simulation has ended." << std::endl;
        exit(1);
    }

    if (s -> _right) { s -> _right -> ref_count++; }
    if (s -> _left) { s -> _left -> ref_count++; }

    if (!STARTED) {
        springs.push_back(s);
        return s;
    } else {
        if (RUNNING) {
            exit(1);
        }

        springs.push_back(s);

        CUDA_SPRING * d_spring;
        gpuErrchk(cudaMalloc((void **) &d_spring, sizeof(CUDA_SPRING)));
        s -> arrayptr = d_spring;
        d_springs.push_back(d_spring);

        CUDA_SPRING temp = CUDA_SPRING(*s);
        gpuErrchk(cudaMemcpy(d_spring, &temp, sizeof(CUDA_SPRING), cudaMemcpyHostToDevice));

#ifdef GRAPHICS
        resize_buffers = true;
#endif
        return s;
    }
}

Spring * Simulation::createSpring() {
    if (ENDED) {
        std::cerr << "simulation has ended." << std::endl;
        exit(1);
    }

    Spring * s = new Spring();
    return createSpring(s);
}

Spring * Simulation::createSpring(Mass * m1, Mass * m2) {
    if (ENDED) {
        std::cerr << "simulation has ended." << std::endl;
        exit(1);
    }

    Spring * s = new Spring(m1, m2);
    return createSpring(s);
}

__global__ void invalidate(CUDA_MASS ** ptrs, CUDA_MASS * m, int size) {
    int i = blockDim.x * blockIdx.x + threadIdx.x;

    if (i < size) {
        if (ptrs[i] == m) {
            m -> valid = false;
        }
    }
}

void Simulation::deleteMass(Mass * m) {
    if (ENDED) {
        std::cerr << "simulation has ended." << std::endl;
        exit(1);
    }

    if (!STARTED) {
        masses.resize(std::remove(masses.begin(), masses.end(), m) - masses.begin());
        m -> decrementRefCount();
    } else {
        if (RUNNING) {
            exit(1);
        }

        updateCudaParameters();
        invalidate<<<massBlocksPerGrid, THREADS_PER_BLOCK>>>(d_mass, m -> arrayptr, masses.size());
        m -> valid = false;


        thrust::remove(thrust::device, d_masses.begin(), d_masses.begin() + masses.size(), m -> arrayptr);
        masses.resize(std::remove(masses.begin(), masses.end(), m) - masses.begin());

        d_masses.resize(masses.size());

        m -> decrementRefCount();


#ifdef GRAPHICS
        resize_buffers = true;
#endif
    }
}

void Simulation::deleteSpring(Spring * s) {
    if (ENDED) {
        std::cerr << "simulation has ended." << std::endl;
        exit(1);
    }

    if (!STARTED) {
        springs.resize(std::remove(springs.begin(), springs.end(), s) - springs.begin());

        if (s -> _left) { s -> _left -> decrementRefCount(); }
        if (s -> _right) { s -> _right -> decrementRefCount(); }

    } else {
        if (RUNNING) {
            exit(1);
        }

        gpuErrchk(cudaFree(s -> arrayptr));
        thrust::remove(thrust::device, d_springs.begin(), d_springs.begin() + springs.size(), s -> arrayptr);

        springs.resize(std::remove(springs.begin(), springs.end(), s) - springs.begin());

        if (s -> _left) { s -> _left -> decrementRefCount(); }
        if (s -> _right) { s -> _right -> decrementRefCount(); }

        delete s;

#ifdef GRAPHICS
        resize_buffers = true;
#endif
    }
}

struct mass_in_list {
    __device__ __host__ mass_in_list(CUDA_MASS ** ptr, int n) : list(ptr), size(n) {};

    __device__ __host__ bool operator()(CUDA_MASS * data) {
        for (int i = 0; i < size; i++) {
            if (list[i] == data) {
                data -> valid = false;
                return true;
            }
        }

        return false;
    }

    CUDA_MASS ** list;
    int size;
};

struct spring_in_list {
    __device__ __host__ spring_in_list(CUDA_SPRING ** ptr, int n) : list(ptr), size(n) {};

    __device__ __host__ bool operator()(CUDA_SPRING * data) {
        for (int i = 0; i < size; i++) {
            if (list[i] == data) {
                return true;
            }
        }

        return false;
    }

    CUDA_SPRING ** list;
    int size;
};

struct host_mass_in_list {
    __device__ __host__ host_mass_in_list(Mass ** ptr, int n) : list(ptr), size(n) {};

    __device__ __host__ bool operator()(Mass * data) {
        for (int i = 0; i < size; i++) {
            if (list[i] == data) {
                return true;
            }
        }

        return false;
    }

    Mass ** list;
    int size;
};


struct host_spring_in_list {
    __device__ __host__ host_spring_in_list(Spring ** ptr, int n) : list(ptr), size(n) {};

    __device__ __host__ bool operator()(Spring * data) {
        for (int i = 0; i < size; i++) {
            if (list[i] == data) {
                return true;
            }
        }

        return false;
    }

    Spring ** list;
    int size;
};

void Simulation::deleteContainer(Container * c) {
    if (ENDED) {
        std::cerr << "simulation has ended." << std::endl;
        exit(1);
    }

    if (RUNNING) {
        std::cerr << "simulation is running." << std::endl;
        exit(1);
    }

    if (!STARTED) {
        for (Mass * m : c -> masses) {
            deleteMass(m);
        }

        for (Spring * s : c -> springs) {
            deleteSpring(s);
        }

        delete c;
        objs.resize(std::remove(objs.begin(), objs.end(), c) - objs.begin());

        return;
    }

    {
        std::cout << "deleting masses" << std::endl;

        CUDA_MASS ** d_ptrs = new CUDA_MASS * [c -> masses.size()];

        for (int i = 0; i < c -> masses.size(); i++) {
            d_ptrs[i] = c -> masses[i] -> arrayptr;
            c -> masses[i] -> valid = false;
            c -> masses[i] -> decrementRefCount();
        }

        masses.resize(thrust::remove_if(thrust::host, masses.begin(), masses.end(), host_mass_in_list(c -> masses.data(), c -> masses.size())) - masses.begin());

        CUDA_MASS ** temp;
        gpuErrchk(cudaMalloc((void **) &temp, sizeof(CUDA_MASS *) * c -> masses.size()));
        gpuErrchk(cudaMemcpy(temp, d_ptrs, c -> masses.size() * sizeof(CUDA_MASS *), cudaMemcpyHostToDevice));
        delete [] d_ptrs;

        thrust::remove_if(thrust::device, d_masses.begin(), d_masses.begin() + masses.size() + c -> masses.size(), mass_in_list(temp, c -> masses.size()));
        d_masses.resize(masses.size());

        gpuErrchk(cudaFree(temp));
    }

    {
        std::cout << "deleting springs" << std::endl;

        CUDA_SPRING ** d_ptrs = new CUDA_SPRING * [c -> springs.size()];

        for (int i = 0; i < c -> springs.size(); i++) {
            Spring * s = c -> springs[i];

            d_ptrs[i] = s -> arrayptr;
            gpuErrchk(cudaFree(s -> arrayptr));

            if (s -> _left) { s -> _left -> decrementRefCount(); }
            if (s -> _right) { s -> _right -> decrementRefCount(); }
        }

        springs.resize(thrust::remove_if(thrust::host, springs.begin(), springs.end(), host_spring_in_list(c -> springs.data(), c -> springs.size())) - springs.begin());

        CUDA_SPRING ** temp;
        gpuErrchk(cudaMalloc((void **) &temp, sizeof(CUDA_SPRING *) * c -> springs.size()));
        gpuErrchk(cudaMemcpy(temp, d_ptrs, c -> springs.size() * sizeof(CUDA_SPRING *), cudaMemcpyHostToDevice));
        delete [] d_ptrs;

        std::cout << "remove called" << std::endl;

        thrust::remove_if(thrust::device, d_springs.begin(), d_springs.begin() + springs.size() + c -> springs.size(), spring_in_list(temp, c -> springs.size()));
        d_springs.resize(springs.size());

        gpuErrchk(cudaFree(temp));

        std::cout << "done" << std::endl;
    }

#ifdef GRAPHICS // TODO make a decision about this
    resize_buffers = true;
#endif

    delete c;
    objs.resize(std::remove(objs.begin(), objs.end(), c) - objs.begin());
}

//void Simulation::deleteContainer(Container * c) {
//    if (RUNNING) {
//        exit(1);
//    }
//
//    std::cout << c -> masses.size() << " " << c -> springs.size() << std::endl;
//
//    for (Mass * m : c -> masses) {
//        deleteMass(m);
//    }
//
//    for (Spring * s : c -> springs) {
//        deleteSpring(s);
//    }
//
//#ifdef GRAPHICS
//    resize_buffers = true;
//#endif
//
//    delete c;
//    objs.remove(c);
//}

void Simulation::get(Mass * m) {
    if (!STARTED) {
        std::cerr << "Simulation has not started." << std::endl;
        return;
    }

    if (ENDED) {
        std::cerr << "simulation has ended." << std::endl;
        exit(1);
    }

    CUDA_MASS temp;
    gpuErrchk(cudaMemcpy(&temp, m -> arrayptr, sizeof(CUDA_MASS), cudaMemcpyDeviceToHost));
    *m = temp;
}

void Simulation::set(Mass * m) {
    if (!STARTED) {
        std::cerr << "Simulation has not started." << std::endl;
        return;
    }

    if (ENDED) {
        std::cerr << "simulation has ended." << std::endl;
        exit(1);
    }

    CUDA_MASS temp = CUDA_MASS(*m);
    gpuErrchk(cudaMemcpy(m -> arrayptr, &temp, sizeof(CUDA_MASS), cudaMemcpyHostToDevice));
}

void Simulation::get(Spring * s) {
    if (!STARTED) {
        std::cerr << "Simulation has not started." << std::endl;
        return;
    }

    if (ENDED) {
        std::cerr << "simulation has ended." << std::endl;
        exit(1);
    }

    CUDA_SPRING temp;
    gpuErrchk(cudaMemcpy(&temp, s -> arrayptr, sizeof(CUDA_SPRING), cudaMemcpyDeviceToHost));
    *s = Spring(temp);
}

void Simulation::set(Spring * s) {
    if (!STARTED) {
        std::cerr << "Simulation has not started." << std::endl;
        return;
    }

    CUDA_SPRING temp = CUDA_SPRING(*s);
    gpuErrchk(cudaMemcpy(s -> arrayptr, &temp, sizeof(CUDA_SPRING), cudaMemcpyHostToDevice));
}

void Simulation::getAll() {
    if (!STARTED) {
        std::cerr << "Simulation has not started." << std::endl;
        return;
    }

    if (ENDED) {
        std::cerr << "simulation has ended." << std::endl;
        exit(1);
    }

    massFromArray(); // TODO make a note of this
}

void Simulation::set(Container * c) {
    {
        if (ENDED) {
            std::cerr << "simulation has ended." << std::endl;
            exit(1);
        }

        CUDA_MASS * h_data = new CUDA_MASS[c -> masses.size()]; // copy masses into single array for copying to the GPU, set GPU pointers
        CUDA_MASS ** d_ptrs = new CUDA_MASS * [c -> masses.size()];

        for (int i = 0; i < c -> masses.size(); i++) {
            d_ptrs[i] = c -> masses[i] -> arrayptr;
            h_data[i] = CUDA_MASS(*c -> masses[i]);
        }

        CUDA_MASS ** temp;
        gpuErrchk(cudaMalloc((void **) &temp, sizeof(CUDA_MASS *) * c -> masses.size()));
        gpuErrchk(cudaMemcpy(temp, d_ptrs, c -> masses.size() * sizeof(CUDA_MASS *), cudaMemcpyHostToDevice));
        delete [] d_ptrs;

        CUDA_MASS * d_data; // copy to the GPU
        gpuErrchk(cudaMalloc((void **)&d_data, sizeof(CUDA_MASS) * c -> masses.size()));
        gpuErrchk(cudaMemcpy(d_data, h_data, sizeof(CUDA_MASS) * c -> masses.size(), cudaMemcpyHostToDevice));
        delete [] h_data;

        updateCudaParameters();
        createMassPointers<<<massBlocksPerGrid, THREADS_PER_BLOCK>>>(temp, d_data, c -> masses.size());

        gpuErrchk(cudaFree(d_data));
        gpuErrchk(cudaFree(temp));
    }

    {
        CUDA_SPRING * h_spring = new CUDA_SPRING[c -> springs.size()];
        CUDA_SPRING ** d_ptrs = new CUDA_SPRING *[c -> springs.size()];

        int count = 0;
        for (Spring * s : springs) {
            d_ptrs[count] = c -> springs[count] -> arrayptr;
            h_spring[count] = CUDA_SPRING(*s, s -> _left -> arrayptr, s -> _right -> arrayptr);
            count++;
        }

        CUDA_SPRING ** temp;
        gpuErrchk(cudaMalloc((void **) &temp, sizeof(CUDA_SPRING *) * c -> springs.size()));
        gpuErrchk(cudaMemcpy(temp, d_ptrs, c -> springs.size() * sizeof(CUDA_SPRING *), cudaMemcpyHostToDevice));
        delete [] d_ptrs;

        CUDA_SPRING * d_data;
        gpuErrchk(cudaMalloc((void **)& d_data, sizeof(CUDA_SPRING) * springs.size()));
        gpuErrchk(cudaMemcpy(d_data, h_spring, sizeof(CUDA_SPRING) * springs.size(), cudaMemcpyHostToDevice));
        delete [] h_spring;

        createSpringPointers<<<springBlocksPerGrid, THREADS_PER_BLOCK>>>(temp, d_data, springs.size());

        gpuErrchk(cudaFree(d_data));
        gpuErrchk(cudaFree(temp));
    }
}

void Simulation::setAll() {
    if (ENDED) {
        std::cerr << "simulation has ended." << std::endl;
        exit(1);
    }

    {
        CUDA_MASS * h_data = new CUDA_MASS[masses.size()]; // copy masses into single array for copying to the GPU, set GPU pointers

        int count = 0;

        for (Mass * m : masses) {
            h_data[count] = CUDA_MASS(*m);
            count++;
        }

        CUDA_MASS * d_data; // copy to the GPU
        gpuErrchk(cudaMalloc((void **)&d_data, sizeof(CUDA_MASS) * masses.size()));
        gpuErrchk(cudaMemcpy(d_data, h_data, sizeof(CUDA_MASS) * masses.size(), cudaMemcpyHostToDevice));

        delete [] h_data;

        updateCudaParameters();
        createMassPointers<<<massBlocksPerGrid, THREADS_PER_BLOCK>>>(thrust::raw_pointer_cast(d_masses.data()), d_data, masses.size());

        gpuErrchk(cudaFree(d_data));
    }

    {
        CUDA_SPRING * h_spring = new CUDA_SPRING[springs.size()];

        int count = 0;
        for (Spring * s : springs) {
            h_spring[count] = CUDA_SPRING(*s, s -> _left -> arrayptr, s -> _right -> arrayptr);
            count++;
        }

        CUDA_SPRING * d_data;
        gpuErrchk(cudaMalloc((void **)& d_data, sizeof(CUDA_SPRING) * springs.size()));
        gpuErrchk(cudaMemcpy(d_data, h_spring, sizeof(CUDA_SPRING) * springs.size(), cudaMemcpyHostToDevice));

        delete [] h_spring;

        createSpringPointers<<<springBlocksPerGrid, THREADS_PER_BLOCK>>>(thrust::raw_pointer_cast(d_springs.data()), d_data, springs.size());
        gpuErrchk(cudaFree(d_data));
    }
}



void Simulation::setSpringConstant(double k) {
    if (ENDED) {
        std::cerr << "simulation has ended." << std::endl;
        exit(1);
    }

    for (Spring * s : springs) {
        s -> _k = k;
    }
}

void Simulation::defaultRestLength() {
    if (ENDED) {
        std::cerr << "simulation has ended." << std::endl;
        exit(1);
    }

    for (Spring * s : springs) {
        s -> defaultLength();
    }
}

void Simulation::setMassValues(double m) {
    if (ENDED) {
        std::cerr << "simulation has ended." << std::endl;
        exit(1);
    }

    for (Mass * mass : masses) {
        mass -> m += m;
    }
}
void Simulation::setDeltaT(double dt) {
    if (ENDED) {
        std::cerr << "simulation has ended." << std::endl;
        exit(1);
    }

    for (Mass * m : masses) {
        m -> dt += dt;
    }
}

void Simulation::setBreakpoint(double time) {
    if (ENDED) {
        std::cerr << "simulation has ended." << std::endl;
        exit(1);
    }

    bpts.insert(time); // TODO mutex breakpoints
}

__global__ void createMassPointers(CUDA_MASS ** ptrs, CUDA_MASS * data, int size) {
    int i = blockDim.x * blockIdx.x + threadIdx.x;

    if (i < size) {
//        ptrs[i] = (CUDA_MASS *) malloc(sizeof(CUDA_MASS));
        *ptrs[i] = data[i];
    }
}

CUDA_MASS ** Simulation::massToArray() {
    CUDA_MASS ** d_ptrs = new CUDA_MASS * [masses.size()]; // array of pointers
    for (int i = 0; i < masses.size(); i++) { // potentially slow
        gpuErrchk(cudaMalloc((void **) d_ptrs + i, sizeof(CUDA_MASS *)));
    }

    d_masses = thrust::device_vector<CUDA_MASS *>(d_ptrs, d_ptrs + masses.size());


    CUDA_MASS * h_data = new CUDA_MASS[masses.size()]; // copy masses into single array for copying to the GPU, set GPU pointers

    int count = 0;

    for (Mass * m : masses) {
        m -> arrayptr = d_ptrs[count];
        h_data[count] = CUDA_MASS(*m);

        count++;
    }

    delete [] d_ptrs;



    CUDA_MASS * d_data; // copy to the GPU
    gpuErrchk(cudaMalloc((void **)&d_data, sizeof(CUDA_MASS) * masses.size()));
    gpuErrchk(cudaMemcpy(d_data, h_data, sizeof(CUDA_MASS) * masses.size(), cudaMemcpyHostToDevice));

    delete [] h_data;


    massBlocksPerGrid = (masses.size() + THREADS_PER_BLOCK - 1) / THREADS_PER_BLOCK;

    if (massBlocksPerGrid > MAX_BLOCKS) {
        massBlocksPerGrid = MAX_BLOCKS;
    }

    createMassPointers<<<massBlocksPerGrid, THREADS_PER_BLOCK>>>(thrust::raw_pointer_cast(d_masses.data()), d_data, masses.size());
    gpuErrchk(cudaFree(d_data));

    return thrust::raw_pointer_cast(d_masses.data()); // doesn't really do anything
}

__global__ void createSpringPointers(CUDA_SPRING ** ptrs, CUDA_SPRING * data, int size) {
    int i = blockDim.x * blockIdx.x + threadIdx.x;

    if (i < size) {
//        ptrs[i] = (CUDA_SPRING *) malloc(sizeof(CUDA_SPRING));
        *ptrs[i] = data[i];
    }
}

CUDA_SPRING ** Simulation::springToArray() {
    if (ENDED) {
        std::cerr << "simulation has ended." << std::endl;
        exit(1);
    }

    CUDA_SPRING ** d_ptrs = new CUDA_SPRING * [springs.size()]; // array of pointers
    for (int i = 0; i < springs.size(); i++) { // potentially slow
        gpuErrchk(cudaMalloc((void **) d_ptrs + i, sizeof(CUDA_SPRING *)));
    }

    d_springs = thrust::device_vector<CUDA_SPRING *>(d_ptrs, d_ptrs + springs.size());



    CUDA_SPRING * h_spring = new CUDA_SPRING[springs.size()];

    int count = 0;
    for (Spring * s : springs) {
        s -> arrayptr = d_ptrs[count];
        h_spring[count] = CUDA_SPRING(*s, s -> _left -> arrayptr, s -> _right -> arrayptr);
        count++;
    }

    delete [] d_ptrs;

    CUDA_SPRING * d_data;
    gpuErrchk(cudaMalloc((void **)& d_data, sizeof(CUDA_SPRING) * springs.size()));
    gpuErrchk(cudaMemcpy(d_data, h_spring, sizeof(CUDA_SPRING) * springs.size(), cudaMemcpyHostToDevice));

    delete [] h_spring;

    createSpringPointers<<<springBlocksPerGrid, THREADS_PER_BLOCK>>>(thrust::raw_pointer_cast(d_springs.data()), d_data, springs.size());
    gpuErrchk(cudaFree(d_data));

    return thrust::raw_pointer_cast(d_springs.data());
}

//void Simulation::constraintsToArray() {
//    d_constraints.reserve(constraints.size());
//
//    for (Constraint * c : constraints) {
//        Constraint * d_temp;
//        cudaMalloc((void **)& d_temp, sizeof(Constraint));
//        cudaMemcpy(d_temp, c, sizeof(Constraint), cudaMemcpyHostToDevice);
//        d_constraints.push_back(d_temp);
//    }
//}

void Simulation::toArray() {
    if (ENDED) {
        std::cerr << "simulation has ended." << std::endl;
        exit(1);
    }

    CUDA_MASS ** d_mass = massToArray(); // must come first
    CUDA_SPRING ** d_spring = springToArray();
}

__global__ void fromMassPointers(CUDA_MASS ** d_mass, CUDA_MASS * data, int size) {
    int i = blockDim.x * blockIdx.x + threadIdx.x;

    if (i < size) {
        data[i] = *d_mass[i];
    }
}

void Simulation::get(Container *c) {
    if (ENDED) {
        std::cerr << "simulation has ended." << std::endl;
        exit(1);
    }

    CUDA_MASS ** temp;

    gpuErrchk(cudaMalloc((void **) &temp, sizeof(CUDA_MASS *) * c -> masses.size()));

    CUDA_MASS ** d_ptrs = new CUDA_MASS * [c -> masses.size()];

    for (int i = 0; i < c -> masses.size(); i++) {
        d_ptrs[i] = c -> masses[i] -> arrayptr;
    }

    gpuErrchk(cudaMemcpy(temp, d_ptrs, c -> masses.size() * sizeof(CUDA_MASS *), cudaMemcpyHostToDevice));

    delete [] d_ptrs;

    CUDA_MASS * temp_data;
    gpuErrchk(cudaMalloc((void **) &temp_data, sizeof(CUDA_MASS) * c -> masses.size()));

    updateCudaParameters();
    fromMassPointers<<<massBlocksPerGrid, THREADS_PER_BLOCK>>>(temp, temp_data, c -> masses.size());
    gpuErrchk(cudaFree(temp));

    CUDA_MASS * h_mass = new CUDA_MASS[masses.size()];
    gpuErrchk(cudaMemcpy(h_mass, temp_data, sizeof(CUDA_MASS) * masses.size(), cudaMemcpyDeviceToHost));
    gpuErrchk(cudaFree(temp_data));

    int count = 0;

    for (Mass * m : c -> masses) {
        *m = h_mass[count];
        count++;
    }

    delete [] h_mass;
}

void Simulation::massFromArray() {
    if (ENDED) {
        std::cerr << "simulation has ended." << std::endl;
        exit(1);
    }

    CUDA_MASS * temp;
    gpuErrchk(cudaMalloc((void **) &temp, sizeof(CUDA_MASS) * masses.size()));

    fromMassPointers<<<massBlocksPerGrid, THREADS_PER_BLOCK>>>(d_mass, temp, masses.size());

    CUDA_MASS * h_mass = new CUDA_MASS[masses.size()];
    gpuErrchk(cudaMemcpy(h_mass, temp, sizeof(CUDA_MASS) * masses.size(), cudaMemcpyDeviceToHost));
    gpuErrchk(cudaFree(temp));

    int count = 0;

    Mass temp_data;

    for (Mass * m : masses) {
        *m = h_mass[count];
        count++;
    }

    delete [] h_mass;

//    cudaFree(d_mass);
}

void Simulation::springFromArray() {
//    cudaFree(d_spring);
}

void Simulation::constraintsFromArray() {
    //
}

void Simulation::fromArray() {
    if (ENDED) {
        std::cerr << "simulation has ended." << std::endl;
        exit(1);
    }

    massFromArray();
    springFromArray();
    constraintsFromArray();
}

__global__ void printMasses(CUDA_MASS ** d_masses, int num_masses) {
    int i = blockDim.x * blockIdx.x + threadIdx.x;

    if (i < num_masses) {
        CUDA_MASS data = *d_masses[i];
        printf("%d: (%3f, %3f, %3f)", i, data.pos[0], data.pos[1], data.pos[2]);
    }
}

__global__ void printForce(CUDA_MASS ** d_masses, int num_masses) {
    int i = blockDim.x * blockIdx.x + threadIdx.x;

    if (i < num_masses) {
        Vec & data = d_masses[i] -> force;
        printf("%d: (%3f, %3f, %3f)\n", i, data[0], data[1], data[2]);
    }
}

__global__ void printSpring(CUDA_SPRING ** d_springs, int num_springs) {
    int i = blockDim.x * blockIdx.x + threadIdx.x;

    if (i < num_springs) {
        CUDA_SPRING data = *d_springs[i];
        printf("%d: left: (%5f, %5f, %5f), right:  (%5f, %5f, %5f), k: %f, rest: %f\n ", i, data._left -> pos[0], data._left -> pos[1], data._left -> pos[2], data._right -> pos[0], data._right -> pos[1], data._right -> pos[2], data._k, data._rest);
    }
}

//__global__ void printSpringForce(CUDA_SPRING * d_springs, int num_springs) {
//    int i = blockDim.x * blockIdx.x + threadIdx.x;
//
//    if (i < num_springs) {
//        printf("%d: left: (%5f, %5f, %5f), right:  (%5f, %5f, %5f)\n\n ", i, d_springs[i]._left -> force[0], d_springs[i]._left -> force[1], d_springs[i]._left -> force[2], d_springs[i]._right -> force[0], d_springs[i]._right -> force[1], d_springs[i]._right -> force[2]);
//    }
//}

__global__ void computeSpringForces(CUDA_SPRING ** d_spring, int num_springs) {
    int i = blockDim.x * blockIdx.x + threadIdx.x;

    if ( i < num_springs ) {
        CUDA_SPRING & spring = *d_spring[i];

        if (spring._left == nullptr || spring._right == nullptr || ! spring._left -> valid || ! spring._right -> valid)
            return;

        Vec temp = (spring._right -> pos) - (spring._left -> pos);
        Vec force = spring._k * (spring._rest - temp.norm()) * (temp / temp.norm());

#ifdef CONSTRAINTS
        if (spring._right -> constraints.fixed == false) {
            spring._right->force.atomicVecAdd(force); // need atomics here
        }
        if (spring._left -> constraints.fixed == false) {
            spring._left->force.atomicVecAdd(-force);
        }
#else
        spring._right->force.atomicVecAdd(force);
        spring._left->force.atomicVecAdd(-force);
#endif

    }
}

__global__ void massForcesAndUpdate(CUDA_MASS ** d_mass, CUDA_GLOBAL_CONSTRAINTS c, int num_masses) {
    int i = blockDim.x * blockIdx.x + threadIdx.x;

    if (i < num_masses) {
        CUDA_MASS &mass = *d_mass[i];

#ifdef CONSTRAINTS
        if (mass.constraints.fixed == 1)
            return;
#endif

        mass.force += Vec(0, 0, - G * mass.m); // gravity

        for (int j = 0; j < c.num_planes; j++) { // global constraints
            c.d_planes[j].applyForce(&mass);
        }

        for (int j = 0; j < c.num_balls; j++) {
            c.d_balls[j].applyForce(&mass);
        }

#ifdef CONSTRAINTS
        for (int j = 0; j < mass.constraints.num_contact_planes; j++) { // local constraints
            mass.constraints.contact_plane[j].applyForce(&mass);
        }

        for (int j = 0; j < mass.constraints.num_balls; j++) {
            mass.constraints.ball[j].applyForce(&mass);
        }

        for (int j = 0; j < mass.constraints.num_constraint_planes; j++) {
            mass.constraints.constraint_plane[j].applyForce(&mass);
        }

        for (int j = 0; j < mass.constraints.num_directions; j++) {
            mass.constraints.direction[j].applyForce(&mass);
        }

        if (mass.vel.norm() != 0.0) {
            mass.force += - mass.constraints.drag_coefficient * pow(mass.vel.norm(), 2) * mass.vel / mass.vel.norm(); // drag
        }
#endif

        mass.acc = mass.force / mass.m;
        mass.vel = mass.vel + mass.acc * mass.dt;
        mass.pos = mass.pos + mass.vel * mass.dt;

        mass.force = Vec(0, 0, 0);
    }
}

#ifdef GRAPHICS
void Simulation::clearScreen() {
    // Clear the screen
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT); // clear screen

    // Use our shader
    glUseProgram(programID);

    // Send our transformation to the currently bound shader in the "MVP" uniform
    glUniformMatrix4fv(MatrixID, 1, GL_FALSE, &MVP[0][0]);
}

void Simulation::renderScreen() {
    // Swap buffers
#ifdef SDL2
    SDL_GL_SwapWindow(window);
#else
    glfwPollEvents();
    glfwSwapBuffers(window);
#endif
}

#ifdef SDL2

void Simulation::createSDLWindow() {

    if (SDL_Init(SDL_INIT_VIDEO) < 0)
    {
        std::cout << "Failed to init SDL\n";
        return;
    }

    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3);

    SDL_GL_SetAttribute(SDL_GL_RED_SIZE, 8);
    SDL_GL_SetAttribute(SDL_GL_GREEN_SIZE, 8);
    SDL_GL_SetAttribute(SDL_GL_BLUE_SIZE, 8);
    SDL_GL_SetAttribute(SDL_GL_ALPHA_SIZE, 8);

    // Turn on double buffering with a 24bit Z buffer.
    // You may need to change this to 16 or 32 for your system
    SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
    SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, 24);

    SDL_GL_SetAttribute(SDL_GL_MULTISAMPLEBUFFERS, 1);
    SDL_GL_SetAttribute(SDL_GL_MULTISAMPLESAMPLES, 4);

    SDL_GL_SetSwapInterval(1);

    // Open a window and create its OpenGL context

    window = SDL_CreateWindow("CUDA Physics Simulation", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, 1024, 768, SDL_WINDOW_OPENGL);
    SDL_SetWindowResizable(window, SDL_TRUE);

    if (window == NULL) {
        fprintf(stderr,
                "Failed to open SDL window. If you have an Intel GPU, they are not 3.3 compatible. Try the 2.1 version of the tutorials.\n");
        getchar();
        SDL_Quit();
        return;
    }

    context = SDL_GL_CreateContext(window);

    // Initialize GLEW
    glewExperimental = true; // Needed for core profile
    if (glewInit() != GLEW_OK) {
        fprintf(stderr, "Failed to initialize GLEW\n");
        getchar();
        SDL_Quit();
        return;
    }

    glEnable(GL_DEPTH_TEST);
    //    // Accept fragment if it closer to the camera than the former one
    glDepthFunc(GL_LESS);

    // Dark blue background
    glClearColor(0.0f, 0.0f, 0.0f, 0.0f);

    glEnable(GL_MULTISAMPLE);

}

#else
void framebuffer_size_callback(GLFWwindow* window, int width, int height)
{
    glViewport(0, 0, width, height);
}

void Simulation::createGLFWWindow() {
    // Initialise GLFW
    if( !glfwInit() ) // TODO throw errors here
    {
        fprintf( stderr, "Failed to initialize GLFW\n" );
        getchar();
        exit(1);
    }

    glfwWindowHint(GLFW_SAMPLES, 4);
    glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 3);
    glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 3);
    glfwWindowHint(GLFW_OPENGL_FORWARD_COMPAT, GL_TRUE); // To make MacOS happy; should not be needed
    glfwWindowHint(GLFW_OPENGL_PROFILE, GLFW_OPENGL_CORE_PROFILE); //We don't want the old OpenGL
    glfwWindowHint(GLFW_RESIZABLE, GL_TRUE);

    glfwSwapInterval(1);

    // Open a window and create its OpenGL context
    window = glfwCreateWindow(1024, 768, "CUDA Physics Simulation", NULL, NULL);

    if (window == NULL) {
        fprintf(stderr,
                "Failed to open GLFW window. If you have an Intel GPU, they are not 3.3 compatible. Try the 2.1 version of the tutorials.\n");
        getchar();
        glfwTerminate();
        exit(1);
    }

    glfwMakeContextCurrent(window);
    glfwSetFramebufferSizeCallback(window, framebuffer_size_callback);

    glEnable(GL_DEPTH_TEST);
    //    // Accept fragment if it closer to the camera than the former one
    glDepthFunc(GL_LESS);

    // Initialize GLEW
    glewExperimental = true; // Needed for core profile
    if (glewInit() != GLEW_OK) {
        fprintf(stderr, "Failed to initialize GLEW\n");
        getchar();
        glfwTerminate();
        exit(1);
    }


    // Ensure we can capture the escape key being pressed below
    glfwSetInputMode(window, GLFW_STICKY_KEYS, GL_TRUE);

    // Dark blue background
    glClearColor(0.0f, 0.0f, 0.0f, 0.0f);
}

#endif
#endif

void Simulation::stop() {
    if (RUNNING) {
        std::cerr << "simulation is running." << std::endl;
        exit(1);
    }

    ENDED = true;

    while (!FREED) {
        std::this_thread::sleep_for(std::chrono::microseconds(10));
    }

    std::cout << "freed!" << std::endl;

    return;
}

void Simulation::stop(double time) {
    if (ENDED) {
        std::cerr << "simulation has ended." << std::endl;
        exit(1);
    }

    stop_time = time;
    pause(time);

    while (!ENDED) {
        std::this_thread::sleep_for(std::chrono::microseconds(10));
    }

    return;
}

void Simulation::start() {
    if (ENDED) {
        std::cerr << "simulation has ended." << std::endl;
        exit(1);
    }

    if (masses.size() == 0) {
        std::cerr << "No masses have been added. Please add masses before starting the simulation." << std::endl;
        exit(1);
    }

    std::cout << "Starting simulation with " << masses.size() << " masses and " << springs.size() << " springs." << std::endl;
    
    setBreakpoint(time);

    RUNNING = true;
    STARTED = true;

    T = 0;

    dt = 0.01; // min delta

    for (Mass * m : masses) {
        if (m -> dt < dt)
            dt = m -> dt;
    }

#ifdef GRAPHICS // SDL2 window needs to be created here for Mac OS
#ifdef SDL2
    createSDLWindow();
#endif
#endif

    updateCudaParameters();

    d_constraints.d_balls = thrust::raw_pointer_cast(&d_balls[0]);
    d_constraints.d_planes = thrust::raw_pointer_cast(&d_planes[0]);
    d_constraints.num_balls = d_balls.size();
    d_constraints.num_planes = d_planes.size();

    update_constraints = false;

//    cudaDeviceSetLimit(cudaLimitMallocHeapSize, 5 * (masses.size() * sizeof(CUDA_MASS) + springs.size() * sizeof(CUDA_SPRING)));
    toArray();

    d_mass = thrust::raw_pointer_cast(d_masses.data());
    d_spring = thrust::raw_pointer_cast(d_springs.data());

    gpu_thread = std::thread(&Simulation::_run, this);
}

void Simulation::_run() { // repeatedly start next
    if (ENDED) {
        std::cerr << "simulation has ended." << std::endl;
        exit(1);
    }

#ifdef GRAPHICS

#ifndef SDL2 // GLFW window needs to be created here for Windows
    createGLFWWindow();
#endif

#ifdef SDL2
    SDL_GL_MakeCurrent(window, context);
#endif
    GLuint VertexArrayID;
    glGenVertexArrays(1, &VertexArrayID);
    glBindVertexArray(VertexArrayID);

//    glEnable(GL_LIGHTING);
//    glEnable(GL_LIGHT0);

    // Create and compile our GLSL program from the shaders
    this -> programID = LoadShaders(); // ("shaders/StandardShading.vertexshader", "shaders/StandardShading.fragmentshader"); //
    // Get a handle for our "MVP" uniform

    this -> MVP = getProjection(Vec(15, 15, 7), Vec(0, 0, 2), Vec(0, 0, 1)); // compute perspective projection matrix

    this -> MatrixID = glGetUniformLocation(programID, "MVP"); // doesn't seem to be necessary

    generateBuffers(); // generate buffers for all masses and springs

    for (Constraint * c : constraints) { // generate buffers for constraint objects
        c -> generateBuffers();
    }

#endif

    execute();
}

void Simulation::updateCudaParameters() {
    if (ENDED) {
        std::cerr << "simulation has ended." << std::endl;
        exit(1);
    }

    massBlocksPerGrid = (masses.size() + THREADS_PER_BLOCK - 1) / THREADS_PER_BLOCK;
    springBlocksPerGrid = (springs.size() + THREADS_PER_BLOCK - 1) / THREADS_PER_BLOCK;

    if (massBlocksPerGrid > MAX_BLOCKS) {
        massBlocksPerGrid = MAX_BLOCKS;
    }

    if (springBlocksPerGrid > MAX_BLOCKS) {
        springBlocksPerGrid = MAX_BLOCKS;
    }

    d_mass = thrust::raw_pointer_cast(d_masses.data());
    d_spring = thrust::raw_pointer_cast(d_springs.data());
}

void Simulation::resume() {
    if (ENDED) {
        std::cerr << "simulation has ended." << std::endl;
        exit(1);
    }

    if (!STARTED) {
        std::cerr << "simulation has not started." << std::endl;
        exit(1);
    }

    if (masses.size() == 0) {
        std::cerr << "No masses have been added. Please add masses before starting the simulation." << std::endl;
        exit(1);
    }

    updateCudaParameters();

    cudaDeviceSynchronize();

    RUNNING = true;
}

void Simulation::execute() {
    while (1) {
        if (!bpts.empty() && *bpts.begin() <= T) {
            cudaDeviceSynchronize(); // synchronize before updating the springs and mass positions
            std::cout << "Breakpoint set for time " << *bpts.begin() << " reached at simulation time " << T << "!" << std::endl;
            bpts.erase(bpts.begin());
            RUNNING = false;

            while (!RUNNING) {
                std::this_thread::sleep_for(std::chrono::microseconds(1));

                if (ENDED) {
                    std::cout << "End of program reached. Exiting GPU thread." << std::endl;
                    return;
                }
            }

#ifdef GRAPHICS
            if (resize_buffers) {
                resizeBuffers(); // needs to be run from GPU thread
                resize_buffers = false;
                update_colors = true;
                update_indices = true;
            }

            if (update_constraints) {
                d_constraints.d_balls = thrust::raw_pointer_cast(&d_balls[0]);
                d_constraints.d_planes = thrust::raw_pointer_cast(&d_planes[0]);
                d_constraints.num_balls = d_balls.size();
                d_constraints.num_planes = d_planes.size();

                for (Constraint * c : constraints) { // generate buffers for constraint objects
                    if (! c -> _initialized)
                        c -> generateBuffers();
                }

                update_constraints = false;
            }
#endif
            continue;
        }

        cudaDeviceSynchronize(); // synchronize before updating the springs and mass positions

#ifdef GRAPHICS
        computeSpringForces<<<springBlocksPerGrid, THREADS_PER_BLOCK>>>(d_spring, springs.size()); // compute mass forces after syncing
        massForcesAndUpdate<<<massBlocksPerGrid, THREADS_PER_BLOCK>>>(d_mass, d_constraints, masses.size());
        T += dt;
#else

        for (int i = 0; i < NUM_QUEUED_KERNELS; i++) {
            computeSpringForces<<<springBlocksPerGrid, THREADS_PER_BLOCK>>>(d_spring, springs.size()); // compute mass forces after syncing
            massForcesAndUpdate<<<massBlocksPerGrid, THREADS_PER_BLOCK>>>(d_mass, d_constraints, masses.size());
            T += dt;
        }
#endif

#ifdef GRAPHICS
        if (fmod(T, 250 * dt) < dt) {
            clearScreen();

            updateBuffers();
            draw();

            for (Constraint * c : constraints) {
                c->draw();
            }

            renderScreen();

#ifndef SDL2
            if (glfwGetKey(window, GLFW_KEY_ESCAPE ) == GLFW_PRESS || glfwWindowShouldClose(window) != 0) {
                RUNNING = 0;
                ENDED = 1;
                break;
            }
#endif
        }
#endif

    }
}

void Simulation::pause(double t) {
    if (ENDED) {
        std::cerr << "simulation has ended." << std::endl;
        exit(1);
    }

    setBreakpoint(t);
    waitForEvent();
}

void Simulation::wait(double t) {
    if (ENDED) {
        std::cerr << "simulation has ended." << std::endl;
        exit(1);
    }


    double current_time = time();
    while (RUNNING && time() <= current_time + t) {
        std::this_thread::sleep_for(std::chrono::microseconds(10));
    }
}

void Simulation::waitUntil(double t) {
    if (ENDED) {
        std::cerr << "simulation has ended." << std::endl;
        exit(1);
    }


    while (RUNNING && time() <= t) {
        std::this_thread::sleep_for(std::chrono::microseconds(10));
    }
}

void Simulation::waitForEvent() {
    if (ENDED) {
        std::cerr << "simulation has ended." << std::endl;
        exit(1);
    }

    while (RUNNING) {
        std::this_thread::sleep_for(std::chrono::microseconds(10));
    }
}

#ifdef GRAPHICS

void Simulation::resizeBuffers() {
//    std::cout << "resizing buffers (" << masses.size() << " masses, " << springs.size() << " springs)." << std::endl;
//    std::cout << "resizing buffers (" << d_masses.size() << " device masses, " << d_springs.size() << " device springs)." << std::endl;
    {
        cudaGLUnregisterBufferObject(this -> colors);
        glBindBuffer(GL_ARRAY_BUFFER, this -> colors);
        glBufferData(GL_ARRAY_BUFFER, 3 * masses.size() * sizeof(GLfloat), NULL, GL_DYNAMIC_DRAW);
        cudaGLRegisterBufferObject(this -> colors);
    }

    {
        cudaGLUnregisterBufferObject(this -> indices);
        glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, this -> indices);
        glBufferData(GL_ELEMENT_ARRAY_BUFFER, 2 * springs.size() * sizeof(GLuint), NULL, GL_DYNAMIC_DRAW); // second argument is number of bytes
        cudaGLRegisterBufferObject(this -> indices);
    }

    {
        cudaGLUnregisterBufferObject(this -> vertices);
        glBindBuffer(GL_ARRAY_BUFFER, vertices);
        glBufferData(GL_ARRAY_BUFFER, 3 * masses.size() * sizeof(GLfloat), NULL, GL_DYNAMIC_DRAW);
        cudaGLRegisterBufferObject(this -> vertices);
    }

    resize_buffers = false;
}

void Simulation::generateBuffers() {
    {
        GLuint colorbuffer; // bind colors to buffer colorbuffer
        glGenBuffers(1, &colorbuffer);
        glBindBuffer(GL_ARRAY_BUFFER, colorbuffer);
        glBufferData(GL_ARRAY_BUFFER, 3 * masses.size() * sizeof(GLfloat), NULL, GL_DYNAMIC_DRAW);
        cudaGLRegisterBufferObject(colorbuffer);
        this -> colors = colorbuffer;
    }

    {
        GLuint elementbuffer; // create buffer for main cube object
        glGenBuffers(1, &elementbuffer);
        glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, elementbuffer);
        glBufferData(GL_ELEMENT_ARRAY_BUFFER, 2 * springs.size() * sizeof(GLuint), NULL, GL_DYNAMIC_DRAW); // second argument is number of bytes
        cudaGLRegisterBufferObject(elementbuffer);
        this -> indices = elementbuffer;
    }

    {
        GLuint vertexbuffer;
        glGenBuffers(1, &vertexbuffer); // bind cube vertex buffer
        glBindBuffer(GL_ARRAY_BUFFER, vertexbuffer);
        glBufferData(GL_ARRAY_BUFFER, 3 * masses.size() * sizeof(GLfloat), NULL, GL_DYNAMIC_DRAW);
        cudaGLRegisterBufferObject(vertexbuffer);
        this -> vertices = vertexbuffer;
    }
}

__global__ void updateVertices(float * gl_ptr, CUDA_MASS ** d_mass, int num_masses) {
    int i = blockDim.x * blockIdx.x + threadIdx.x;

    if (i < num_masses) {
        gl_ptr[3 * i] = (float) d_mass[i] -> pos[0];
        gl_ptr[3 * i + 1] = (float) d_mass[i] -> pos[1];
        gl_ptr[3 * i + 2] = (float) d_mass[i] -> pos[2];
    }
}

__global__ void updateIndices(unsigned int * gl_ptr, CUDA_SPRING ** d_spring, CUDA_MASS ** d_mass, int num_springs, int num_masses) {
    int i = blockDim.x * blockIdx.x + threadIdx.x;

    if (i < num_springs) {
        if (d_spring[i] -> _left == nullptr || d_spring[i] -> _right == nullptr || ! d_spring[i] -> _left -> valid || ! d_spring[i] -> _right -> valid) {
            gl_ptr[2*i] = 0;
            gl_ptr[2*i] = 0;
            return;
        }

        CUDA_MASS * left = d_spring[i] -> _left;
        CUDA_MASS * right = d_spring[i] -> _right;

        for (int j = 0; j < num_masses; j++) {
            if (d_mass[j] == left) {
                gl_ptr[2*i] = j;
            }

            if (d_mass[j] == right) {
                gl_ptr[2*i + 1] = j;
            }
        }
    }
}

__global__ void updateColors(float * gl_ptr, CUDA_MASS ** d_mass, int num_masses) {
    int i = blockDim.x * blockIdx.x + threadIdx.x;

    if (i < num_masses) {
        gl_ptr[3 * i] = (float) d_mass[i] -> color[0];
        gl_ptr[3 * i + 1] = (float) d_mass[i] -> color[1];
        gl_ptr[3 * i + 2] = (float) d_mass[i] -> color[2];
    }
}

void Simulation::updateBuffers() {
    if (update_colors) {
        glBindBuffer(GL_ARRAY_BUFFER, colors);
        void *colorPointer; // if no masses, springs, or colors are changed/deleted, this can be start only once
        cudaGLMapBufferObject(&colorPointer, colors);
        updateColors<<<massBlocksPerGrid, THREADS_PER_BLOCK>>>((float *) colorPointer, d_mass, masses.size());
        cudaGLUnmapBufferObject(colors);
        update_colors = false;
    }


    if (update_indices) {
        glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, indices);
        void *indexPointer; // if no masses or springs are deleted, this can be start only once
        cudaGLMapBufferObject(&indexPointer, indices);
        updateIndices<<<springBlocksPerGrid, THREADS_PER_BLOCK>>>((unsigned int *) indexPointer, d_spring, d_mass, springs.size(), masses.size());
        cudaGLUnmapBufferObject(indices);
        update_indices = false;
    }

    {
        glBindBuffer(GL_ARRAY_BUFFER, vertices);
        void *vertexPointer;
        cudaGLMapBufferObject(&vertexPointer, vertices);
        updateVertices<<<massBlocksPerGrid, THREADS_PER_BLOCK>>>((float *) vertexPointer, d_mass, masses.size());
        cudaGLUnmapBufferObject(vertices);
    }
}

void Simulation::draw() {
    glEnableVertexAttribArray(0);

    glBindBuffer(GL_ARRAY_BUFFER, this -> vertices);
    glPointSize(this -> pointSize);
    glLineWidth(this -> lineWidth);
    glVertexAttribPointer(
            0,                  // attribute. No particular reason for 0, but must match the layout in the shader.
            3,                  // size
            GL_FLOAT,           // type
            GL_FALSE,           // normalized?
            0,                  // stride
            (void*)0            // array buffer offset
    );

    glEnableVertexAttribArray(1);
    glBindBuffer(GL_ARRAY_BUFFER, this -> colors);
    glVertexAttribPointer(
            1,                                // attribute. No particular reason for 1, but must match the layout in the shader.
            3,                                // size
            GL_FLOAT,                         // type
            GL_FALSE,                         // normalized?
            0,                                // stride
            (void*)0                          // array buffer offset
    );

    glDrawArrays(GL_POINTS, 0, masses.size()); // 3 indices starting at 0 -> 1 triangle
    glDrawElements(GL_LINES, 2 * springs.size(), GL_UNSIGNED_INT, (void*) 0); // 3 indices starting at 0 -> 1 triangle

    glDisableVertexAttribArray(1);
    glDisableVertexAttribArray(0);
}

#endif

Container * Simulation::createContainer() {
    Container * c = new Container();
    objs.push_back(c);
    return c;
}

Cube * Simulation::createCube(const Vec & center, double side_length) { // creates half-space ax + by + cz < d
    if (ENDED) {
        std::cerr << "simulation has ended." << std::endl;
        exit(1);
    }

    Cube * cube = new Cube(center, side_length);

    d_masses.reserve(masses.size() + cube -> masses.size());
    d_springs.reserve(springs.size() + cube -> springs.size());

    for (Mass * m : cube -> masses) {
        createMass(m);
    }

    for (Spring * s : cube -> springs) {
        createSpring(s);
    }

    objs.push_back(cube);

    return cube;
}

Lattice * Simulation::createLattice(const Vec & center, const Vec & dims, int nx, int ny, int nz) {
    if (ENDED) {
        std::cerr << "simulation has ended." << std::endl;
        exit(1);
    }

    Lattice * l = new Lattice(center, dims, nx, ny, nz);

    d_masses.reserve(masses.size() + l -> masses.size());
    d_springs.reserve(springs.size() + l -> springs.size());

    for (Mass * m : l -> masses) {
        createMass(m);
    }

    for (Spring * s : l -> springs) {
        createSpring(s);
    }

    objs.push_back(l);

    return l;
}

void Simulation::createPlane(const Vec & abc, double d ) { // creates half-space ax + by + cz < d
    if (ENDED) {
        std::cerr << "simulation has ended." << std::endl;
        exit(1);
    }

    ContactPlane * new_plane = new ContactPlane(abc, d);
    constraints.push_back(new_plane);
    d_planes.push_back(CudaContactPlane(*new_plane));

    update_constraints = true;
}

void Simulation::createBall(const Vec & center, double r ) { // creates ball with radius r at position center
    if (ENDED) {
        std::cerr << "simulation has ended." << std::endl;
        exit(1);
    }

    Ball * new_ball = new Ball(center, r);
    constraints.push_back(new_ball);
    d_balls.push_back(CudaBall(*new_ball));

    update_constraints = true;
}

void Simulation::clearConstraints() { // clears global constraints only
    this -> constraints.clear();
    update_constraints = true;
}

void Simulation::printPositions() {
    if (ENDED) {
        std::cerr << "simulation has ended." << std::endl;
        exit(1);
    }


    if (RUNNING) {
        std::cout << "\nDEVICE MASSES: " << std::endl;
        printMasses<<<massBlocksPerGrid, THREADS_PER_BLOCK>>>(d_mass, masses.size());
        cudaDeviceSynchronize();
    }
    else {
        std::cout << "\nHOST MASSES: " << std::endl;
        int count = 0;
        for (Mass * m : masses) {
            std::cout << count << ": " << m -> pos << std::endl;
            count++;
        }
    }

    std::cout << std::endl;
}

void Simulation::printForces() {
    if (ENDED) {
        std::cerr << "simulation has ended." << std::endl;
        exit(1);
    }


    if (RUNNING) {
        std::cout << "\nDEVICE FORCES: " << std::endl;
        printForce<<<massBlocksPerGrid, THREADS_PER_BLOCK>>>(d_mass, masses.size());
        cudaDeviceSynchronize();
    }
    else {
        std::cout << "\nHOST FORCES: " << std::endl;
        for (Mass * m : masses) {
            std::cout << m -> force << std::endl;
        }
    }

    std::cout << std::endl;
}

void Simulation::printSprings() {
    if (ENDED) {
        std::cerr << "simulation has ended." << std::endl;
        exit(1);
    }

    if (RUNNING) {
        std::cout << "\nDEVICE SPRINGS: " << std::endl;
        printSpring<<<springBlocksPerGrid, THREADS_PER_BLOCK>>>(d_spring, springs.size());
        cudaDeviceSynchronize();
    }
    else {
        std::cout << "\nHOST SPRINGS: " << std::endl;
    }

    std::cout << std::endl;
}

