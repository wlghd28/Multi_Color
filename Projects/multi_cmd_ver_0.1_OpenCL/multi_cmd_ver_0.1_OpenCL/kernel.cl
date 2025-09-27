// TODO: Add OpenCL kernel code here.
//#pragma OPENCL EXTENSION cl_khr_local_int32_base_atomics : enable

__kernel
void simpleKernel(
	__global unsigned char* d_pix,
	__global unsigned char* d_b_pix,
	__global short* d_mask,
	int m_width,
	int b_m_width,
	int height
)
{
	uint dstYStride = get_global_size(0);
	uint dstXStride = get_global_size(1);
	uint globalRow = get_global_id(1);
	uint globalCol = get_global_id(0);
	uint i = globalRow * dstYStride + globalCol * dstXStride;

	int px = i % m_width;
	int py = (i % (b_m_width * height)) / b_m_width;
	int ip = px + py * m_width;
	int mx = (i % b_m_width) / m_width;
	int my = i / (b_m_width * height);
	int im = mx + (4 - my) * 5; // bmp 파일은 뒤집어져서 픽셀이 찍히므로 마스크 값 행렬의 y좌표를 뒤집어준다.
	int rgb_m = (im * 3) + (ip % 3);
	short p, m, sum;

	p = d_pix[ip];
	m = d_mask[rgb_m];
	sum = p + m;
	if (sum >= 255)
		d_b_pix[i] = 255;
	else if (sum < 0)
		d_b_pix[i] = 0;
	else
		d_b_pix[i] = sum;
}