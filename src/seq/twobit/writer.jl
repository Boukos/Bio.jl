# 2bit Writer
# ===========

type Writer{T<:IO} <: Bio.IO.AbstractWriter
    # output stream
    output::T
    # sequence names
    names::Vector{String}
    # bit vector to check if each sequence is already written or not
    written::BitVector
end

"""
    TwoBitWriter(output::IO, names::AbstractVector)

Create a data writer of the 2bit file format.

# Arguments
* `output`: data sink
* `names`: a vector of sequence names written to `output`
"""
function Writer(output::IO, names::AbstractVector)
    writer = Writer(output, names, falses(length(names)))
    write_header(writer)
    write_index(writer)
    return writer
end

function Bio.IO.stream(writer::Writer)
    return writer.output
end

function Base.close(writer::Writer)
    if !all(writer.written)
        error("one or more sequences are not written")
    end
    close(writer.output)
end

function write_header(writer::Writer)
    n = 0
    n += write(writer.output, SIGNATURE)
    n += write(writer.output, UInt32(0))
    n += write(writer.output, UInt32(length(writer.names)))
    n += write(writer.output, UInt32(0))
    return n
end

function write_index(writer::Writer)
    n = 0
    for name in writer.names
        n += write(writer.output, UInt8(length(name)))
        n += write(writer.output, name)
        n += write(writer.output, UInt32(0))  # filled later
    end
    return n
end

# Update the file offset of a sequence in the index section.
function update_offset(writer::Writer, seqname, seqoffset)
    @assert seqname ∈ writer.names
    offset = 16
    for name in writer.names
        offset += sizeof(UInt8) + length(name)
        if name == seqname
            old = position(writer.output)
            seek(writer.output, offset)
            write(writer.output, UInt32(seqoffset))
            seek(writer.output, old)
            return
        end
        offset += sizeof(UInt32)
    end
end

function Base.write(writer::Writer, record::Bio.Seq.SeqRecord)
    i = findfirst(writer.names, record.name)
    if i == 0
        error("sequence \"", record.name, "\" doesn't exist in the writing list")
    elseif writer.written[i]
        error("sequence \"", record.name, "\" is already written")
    end

    output = writer.output
    update_offset(writer, record.name, position(output))

    n = 0
    n += write(output, UInt32(length(record.seq)))
    n += write_n_blocks(output, record.seq)
    n += write_masked_blocks(output, record.metadata)
    n += write(output, UInt32(0))  # reserved bytes
    n += write_twobit_sequence(output, record.seq)

    writer.written[i] = true
    return n
end

function make_n_blocks(seq)
    starts = UInt32[]
    sizes = UInt32[]
    i = 1
    while i ≤ endof(seq)
        nt = seq[i]
        if nt == Bio.Seq.DNA_N
            start = i - 1  # 0-based index
            push!(starts, start)
            while i ≤ endof(seq) && seq[i] == Bio.Seq.DNA_N
                i += 1
            end
            push!(sizes, (i - 1) - start)
        elseif Bio.Seq.isambiguous(nt)
            error("ambiguous nucleotide except N is not supported")
        else
            i += 1
        end
    end
    return starts, sizes
end

function write_n_blocks(output, seq)
    blockstarts, blocksizes = make_n_blocks(seq)
    @assert length(blockstarts) == length(blocksizes)
    n = 0
    n += write(output, UInt32(length(blockstarts)))
    n += write(output, blockstarts)
    n += write(output, blocksizes)
    return n
end

function write_masked_blocks(output, metadata)
    n = 0
    if isa(metadata, Vector{UnitRange{Int}})
        n += write(output, UInt32(length(metadata)))
        for mblock in metadata
            n += write(output, UInt32(first(mblock) - 1))  # 0-based
        end
        for mblock in metadata
            n += write(output, UInt32(length(mblock)))
        end
    elseif metadata === nothing
        n += write(output, UInt32(0))
    else
        error("metadata is not serializable in the 2bit file format")
    end
    return n
end

function write_twobit_sequence(output, seq)
    n = 0
    i = 4
    while i ≤ endof(seq)
        x::UInt8 = 0
        x |= nuc2twobit(seq[i-3]) << 6
        x |= nuc2twobit(seq[i-2]) << 4
        x |= nuc2twobit(seq[i-1]) << 2
        x |= nuc2twobit(seq[i-0]) << 0
        n += write(output, x)
        i += 4
    end
    r = length(seq) % 4
    if r > 0
        let x::UInt8 = 0
            i = endof(seq) - r + 1
            while i ≤ endof(seq)
                x = x << 2 | nuc2twobit(seq[i])
                i += 1
            end
            x <<= (4 - r) * 2
            n += write(output, x)
        end
    end
    return n
end

function nuc2twobit(nt::Bio.Seq.DNA)
    return (
        nt == Bio.Seq.DNA_A ? 0b10 :
        nt == Bio.Seq.DNA_C ? 0b01 :
        nt == Bio.Seq.DNA_G ? 0b11 :
        nt == Bio.Seq.DNA_T ? 0b00 :
        nt == Bio.Seq.DNA_N ? 0b00 : error())
end
