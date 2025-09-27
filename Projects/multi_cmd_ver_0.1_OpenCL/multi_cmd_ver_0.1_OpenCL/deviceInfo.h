#ifndef HISTOGRAM_H_
#define HISTOGRAM_H_
#include <CL/cl.h>

cl_mem d_pix;
cl_mem d_b_pix;
cl_mem d_mask;

cl_platform_id platform;

cl_context          context;
cl_device_id        device;
cl_command_queue    queue;

cl_program program;

cl_kernel  simpleKernel;


#endif  /* #ifndef HISTOGRAM_H_ */
