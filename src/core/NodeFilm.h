// =============================================================================
//  NODE_DRT — film print tables (Node DRT 1.3)
// -----------------------------------------------------------------------------
//  The 7 looks render through a real print: negative then paper, computed by
//  spektrafilm (Andrea Volpato, GPLv3) and stored as one 65^3 table per look
//  (DaVinci Intermediate in, display-linear Rec.709 out, paper white = 1, as
//  logits). The file travels in the bundle: Contents/Resources/Film/
//  film_tables.bin, made by tools/film/gen_film_tables.py. Without it the DCTL
//  falls back to the parametric looks.
// =============================================================================
#pragma once

namespace nodeone {

// Tables as float32 for the CPU path; null (n = 0) when the file is missing.
const float* filmTablesCPU(int& n);
// Same tables as raw float16 (for the GPU), and their byte size.
const void* filmTablesHalf(int& n, unsigned long& bytes);

} // namespace nodeone
