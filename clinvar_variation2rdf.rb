#!/usr/bin/env ruby
#
# Convert ClinVar variant XML file into RDF
#
# Copyright (C) 2017 Toshiaki Katayama <ktym@dbcls.jp>
#
# Pre-requirements:
#  % curl -O ftp://ftp.ncbi.nlm.nih.gov/pub/clinvar/xml/clinvar_variation/beta/variation_archive_20170718.xml.gz
#  % gem install nokogiri
#  % gzip -dc variation_archive_20170718.xml.gz | ruby clinvar2rdf.rb > variation_archive_20170718.rdf
#

# TODO:
# * parse HGVS
# * use FALDO
# * link to Identifiers.org
# * update cvo ontology

require 'rubygems'
require 'nokogiri'
require 'active_support/all'

module TripleSupport
  @@turtle_indent = 1
  @@turtle_tabmax = 4

  def quote(str)
    return str.gsub('\\', '\\\\').gsub("\t", '\\t').gsub("\n", '\\n').gsub("\r", '\\r').gsub('"', '\\"').inspect
  end

  def camelize(str)
    str.gsub(/\s+/, '_').gsub(',', '').camelize
  end

  def quote_date(date)
    return %Q("#{date}"^^xsd:date)
  end

  def usdate2date(str)
    return Date.parse(str).strftime("%Y-%m-%d")
  end

  def new_uuid
    require 'securerandom'
    return "<urn:uuid:#{SecureRandom.uuid}>"
  end

  def triple(subject, predicate, object)
    return [subject, predicate, object].join("\t") + " ."
  end

  def put_spo(subject, predicate, object)
    puts triple(subject, predicate, object)
  end
  
  def put_s(subject)
    puts
    puts subject
  end

  def put_po(predicate, object, separator = ';')
    offset, margin = pad(predicate)
    puts "#{offset}#{predicate}#{margin}#{object} #{separator}"
  end

  def put_blank(predicate, item, separator = ';', &proc)
    offset, margin = pad(predicate)
    puts "#{offset}#{predicate}#{margin}["
    @@turtle_indent += 1
    proc.call(item)
    @@turtle_indent -= 1
    puts "#{offset}] #{separator}"
  end

  def put_blank_po(predicate, object, separator = ';')
    offset, margin = pad(predicate)
    put_po(predicate, object, separator)
  end

  def pad(str)
    offset = "\t" * @@turtle_indent
    margin = "\t" * tab(str)
    return [offset, margin]
  end

  def tab(str)
    tab_max = 4
    if (str.length + 1 > @@turtle_tabmax * 8)
      return 1
    else
      return @@turtle_tabmax - (str.length) / 8
    end
  end
end


module ClinVar

PREFIXES = '# ClinVar ontology
@prefix cvo:                <http://purl.jp/bio/10/clinvar#> .
@prefix exo:                <http://purl.jp/bio/10/exac#> .

@prefix owl:                <http://www.w3.org/2002/07/owl#> .
@prefix rdf:                <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
@prefix rdfs:               <http://www.w3.org/2000/01/rdf-schema#> .
@prefix xsd:                <http://www.w3.org/2001/XMLSchema#> .
@prefix dc:                 <http://purl.org/dc/elements/1.1/> .
@prefix dct:                <http://purl.org/dc/terms/> .
@prefix foaf:               <http://xmlns.com/foaf/0.1/> .
@prefix faldo:              <http://biohackathon.org/resource/faldo#> .
@prefix obo:                <http://purl.obolibrary.org/obo/> .
@prefix sio:                <http://semanticscience.org/resource/> .
@prefix clinvar:            <http://identifiers.org/clinvar/> .
@prefix clinvar_record:     <http://identifiers.org/clinvar.record/> .
@prefix clinvar_submission: <http://identifiers.org/clinvar.submission/> .
@prefix dbsnp:              <http://identifiers.org/dbsnp/> .
@prefix exac_variant:       <http://identifiers.org/exac.variant/> .
@prefix efo:                <http://identifiers.org/efo/> .
@prefix ensembl:            <http://identifiers.org/ensembl/> .
@prefix hgmd:               <http://identifiers.org/hgmd/> .
@prefix hgnc:               <http://identifiers.org/hgnc/> .
@prefix hp:                 <http://identifiers.org/hp/> .
@prefix medgen:             <http://identifiers.org/medgen/> .
@prefix mesh:               <http://identifiers.org/mesh/> .
@prefix ncbigene:           <http://identifiers.org/ncbigene/> .
@prefix omim:               <http://identifiers.org/omim/> .
@prefix orphanet:           <http://identifiers.org/orphanet/> .
@prefix pmc:                <http://identifiers.org/pmc/> .
@prefix pubmed:             <http://identifiers.org/pubmed/> .
@prefix snomedct:           <http://identifiers.org/snomedct/> .
@prefix so:                 <http://identifiers.org/so/> .
@prefix uniprot:            <http://identifiers.org/uniprot/> .
@prefix refseq:             <http://identifiers.org/refseq/> .
@prefix ncbi_bookshelf:     <https://www.ncbi.nlm.nih.gov/books/> .
@prefix uniprot_protein:    <http://purl.uniprot.org/uniprot/> .
@prefix uniprot_annotation: <http://purl.uniprot.org/annotation/> .
@prefix clinvar_homepage:   <https://www.ncbi.nlm.nih.gov/clinvar/variation/> .
'

class Parser
  include TripleSupport

  class UnknownVariationTypeError < StandardError; end

  def initialize(xml)
    @ns = xml.namespaces
    @faldo = FALDO.new
    puts PREFIXES
    parse_clinvar_variation(xml)
  end

  def parse_clinvar_variation(xml)
    xml.xpath('//VariationArchive', @ns).each do |entry|
      next if entry.at('RecordStatus').content != "current"
      @entry = entry
      parse_variation
    end
  end

  def parse_variation
    @subject = "<http://identifiers.org/clinvar/#{@entry['VariationID']}>"

    puts
    put_spo(@subject, "rdf:type", "cvo:Variantion")
    put_spo(@subject, "dct:identifier", quote(@entry['VariationID']))
    put_spo(@subject, "rdfs:label", quote(@entry['VariationName']))
    put_spo(@subject, "cvo:variation_type", quote(@entry['VariationType']))
    assign_variation_type(@entry['VariationType'])
    put_spo(@subject, "cvo:date_created", quote(@entry['DateCreated']))
    put_spo(@subject, "cvo:date_last_updated", quote(@entry['DateLastUpdated']))
    put_spo(@subject, "cvo:accession", quote(@entry['Accession']))
    put_spo(@subject, "cvo:version", quote(@entry['Version']))
    put_spo(@subject, "cvo:record_type", quote(@entry['RecordType']))
    put_spo(@subject, "cvo:number_of_submissions", quote(@entry['NumberOfSubmissions']))
    put_spo(@subject, "cvo:number_of_submitters", quote(@entry['NumberOfSubmitters']))

    put_spo(@subject, "cvo:record_status", quote(@entry.at('RecordStatus').content))
    put_spo(@subject, "cvo:species", quote(@entry.at('Species').content))

    if @entry.at('InterpretedRecord')
      put_spo(@subject, "cvo:record_type_iri", "cvo:InterpretedRecord")
      parse_interpreted_record
    end

    if @entry.at('IncludedRecord')
      put_spo(@subject, "cvo:record_type_iri", "cvo:IncludedRecord")
      # TODO: implement this
      #parse_included_record
    end
  end

  def assign_variation_type(data)
    so_id = false
    case data
    when "single nucleotide variant"
      so_id = "SO:0000694"  # SNP
    when "Indel"
      so_id = "SO:1000032"  # indel
    when "Insertion"
      so_id = "SO:0000667"  # insertion
    when "Deletion"
      so_id = "SO:0000159"  # deletion
    when "Haplotype"
      so_id = "SO:0001024"  # haplotype
    when "Duplication"
      so_id = "SO:1000035"  # duplication
    when "Tandem duplication"
      so_id = "SO:1000173"  # tandem_duplication
    when "Microsatellite"
      so_id = "SO:0000289"  # microsatellite
    when "copy number gain"
      so_id = "SO:0001742"  # copy_number_gain
    when "copy number loss"
      so_id = "SO:0001743"  # copy_number_loss
    when "Translocation"
      so_id = "SO:0000199"  # translocation
    when "Inversion"
      so_id = "SO:1000036"  # inversion
    when "fusion"
      so_id = "SO:0000806"  # fusion
    when "protein only"
      cvo_id = "cvo:VariantType\\/ProteinOnly"
    when "Variation"
      cvo_id = "cvo:VariantType\\/Variation"
    else
      raise UnknownVariationTypeError, data
    end
    if so_id
      put_spo(@subject, "cvo:variation_type_iri", so_id.downcase)
    else
      put_spo(@subject, "cvo:variation_type_iri", cvo_id)
    end
  end

  def parse_interpreted_record
    node = @entry.at('InterpretedRecord')
    if data = node.at('SimpleAllele')
      parse_simple_allele(data)
    end
    if data = node.at('Haplotype')
      # TODO: implement this (now working on this)
      parse_haplotype(data)
    end
    if data = node.at('Genotype')
      # TODO: implement this
      #parse_genotype(data)
    end
  end

  def parse_simple_allele(node)
    put_spo(@subject, "cvo:allele_id", quote(node['AlleleID']))
    put_s(@subject)
    put_blank('cvo:simple_allele', node, '.') do |item|
      parse_gene_list(item.at('GeneList'))
      #parse_name (skip <Name> == <VariationArchive Name>)
      #parse_variation_type (skip <VariantType> == <VariationArchive VariationType>)
      parse_location(item.at('Location'), '.')
      parse_other_name_list(item.at('OtherNameList'))
      parse_protein_change(item.at('ProteinChange'))
      put_blank_po("rdf:type", "cvo:SimpleAllele", '')
    end
    @faldo.to_rdf
  end

  def parse_gene_list(node)
    node.xpath('Gene').each do |gene|
      put_blank("cvo:gene", gene, '.') do |item|
        item.attributes.each do |key, hash|
          case hash.name
          when 'Symbol'
            put_blank_po("cvo:gene_symbol", quote(hash.value))
          when 'FullName'
            put_blank_po("cvo:gene_full_name", quote(hash.value))
          when 'GeneID'
            put_blank_po("cvo:gene_id", quote(hash.value))
            put_blank_po("cvo:gene_ncbi_iri", "ncbigene:#{hash.value}")
          when 'Source'
            put_blank_po("cvo:gene_source", quote(hash.value))
          when 'HGNC_ID'
            put_blank_po("cvo:gene_hgnc_id", quote(hash.value))
            put_blank_po("cvo:gene_hgnc_iri", hash.value.downcase)
          when 'RelationshipType'
            #put_blank_po("cvo:gene_relationship_type", quote(hash.value))
            put_blank_po("cvo:gene_relationship_type", "cvo:RelationshipType\\/#{camelize(hash.value)}")
          end
        end
        parse_location(node.at('Location'))
        if omim = item.at('OMIM')
          put_blank_po("rdfs:seeAlso", "omim:#{omim.content}")
        end
        put_blank_po("rdf:type", "cvo:Gene", '')
      end
    end
  end

  def parse_location(node, separator = ';')
    put_blank("cvo:location", node, separator) do |item|
      if loc = item.at('CytogeneticLocation')
        put_blank_po("cvo:cytogenetic_location", quote(loc.content))
      end
      node.xpath('SequenceLocation').each do |item|
        put_blank("cvo:sequence_location", item) do |loc|
          loc.attributes.each do |key, hash|
            case hash.name
            when 'Assembly'
              put_blank_po("cvo:assembly", quote(hash.value))
            when 'forDisplay'
              put_blank_po("cvo:for_display", quote(hash.value))
            when 'AssemblyAccessionVersion'
              put_blank_po("cvo:assembly_accession_version", quote(hash.value))
            when 'AssemblyStatus'
              put_blank_po("cvo:assembly_status", quote(hash.value))
            when 'Accession'
              put_blank_po("cvo:accession", quote(hash.value))
            when 'Chr'
              put_blank_po("cvo:chr", quote(hash.value))
            when 'start'
              put_blank_po("cvo:start", hash.value)
            when 'stop'
              put_blank_po("cvo:stop", hash.value)
            when 'display_start'
              put_blank_po("cvo:display_start", hash.value)
            when 'display_stop'
              put_blank_po("cvo:display_stop", hash.value)
            when 'variantLength'
              put_blank_po("cvo:variant_length", hash.value)
            when 'referenceAllele'
              put_blank_po("cvo:reference_allele", quote(hash.value))
            when 'alternateAllele'
              put_blank_po("cvo:alternate_allele", quote(hash.value))
            end
          end
          @faldo = FALDO.new(loc['Accession'], loc['start'], loc['stop'], loc['Strand'])
          put_blank_po("faldo:location", @faldo.region)
          put_blank_po("rdf:type", "cvo:SequenceLocation", '')
        end
      end
      put_blank_po("rdf:type", "cvo:Location", '')
    end
  end

  def parse_other_name_list(node)
    if node
      node.xpath('Name').each do |item|
        if names = item.content
          names.split(/,\s+/).each do |name|
            put_po('skos:altLabel', quote(name))
          end
        end
      end
    end
  end

  def parse_protein_change(node)
    if node
      put_po('cvo:protein_change', quote(node.content))
    end
  end

  def parse_haplotype(node)
    put_spo(@subject, "cvo:number_of_copies", quote(node['NumberOfCopies']))
    node.xpath('SimpleAllele').each do |data|
      parse_simple_allele(data)
    end
  end

  def parse_genotype
  end
end

end # module ClinVar

class FALDO
  include TripleSupport

  class UnknownStrandError < StandardError; end

  attr_reader :region

  def initialize(refseq = nil, from = nil, to = nil, strand = nil)
    @faldo_triples = []
    if refseq and from and to
      case strand
      when "+", "1", 1
        direction = 1
      when "-", "-1", -1
        direction = -1
      else
        direction = strand
        raise UnknownStrandError
      end
      @reference = "refseq:#{refseq}"
      @region = "#{@reference}\\#region:#{from}-#{to}:#{direction}"
      construct_faldo_triples(from, to, direction)
    end
  end

  def construct_faldo_triples(from, to, direction)
    if direction > 0
      strand_type = "faldo:ForwardStrandPosition"
    else
      from, to = to, from
      strand_type = "faldo:ReverseStrandPosition"
    end
    start = "#{@reference}\\#position:#{from}:#{direction}"
    stop = "#{@reference}\\#position:#{to}:#{direction}"
    @faldo_triples << [
      [@region, "rdf:type", "faldo:Region"],
      [@region, "faldo:begin", start],
      [@region, "faldo:end", stop],
      [start, "rdf:type", "faldo:ExactPosition"],
      [start, "rdf:type", strand_type],
      [start, "faldo:position", from],
      [start, "faldo:reference", @reference],
      [stop, "rdf:type", "faldo:ExactPosition"],
      [stop, "rdf:type", strand_type],
      [stop, "faldo:position", to],
      [stop, "faldo:reference", @reference],
    ]
  end

  def to_rdf
    @faldo_triples.each do |triples|
      puts
      triples.each do |triple|
        put_spo(*triple)
      end
    end
  end
end

ClinVar::Parser.new(Nokogiri::XML(ARGF))


