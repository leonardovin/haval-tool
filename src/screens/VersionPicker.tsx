import { useEffect, useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { ArrowLeftIcon, PackageIcon, RefreshCwIcon } from 'lucide-react'
import { invoke } from '@tauri-apps/api/core'

type ReleaseInfo = {
  tag: string
  name: string
  apk_url: string
  prerelease: boolean
  published_at: string
}

const LATEST_SENTINEL = '__latest__'

export const VersionPicker = () => {
  const [releases, setReleases] = useState<ReleaseInfo[]>([])
  const [selected, setSelected] = useState<string>(LATEST_SENTINEL)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const navigate = useNavigate()

  const load = async () => {
    setLoading(true)
    setError(null)
    try {
      const data = await invoke<ReleaseInfo[]>('list_haval_releases')
      setReleases(data)
    } catch (e: any) {
      setError(`${e}`)
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => {
    load()
  }, [])

  const handleContinue = () => {
    const apkUrl =
      selected === LATEST_SENTINEL
        ? null
        : releases.find((r) => r.tag === selected)?.apk_url ?? null
    // Forward the chosen URL via router state so Warning → Terminal can pass it
    // into the `inject_script` Tauri command.
    navigate('/install/warning', { state: { apkUrl } })
  }

  return (
    <div className="flex flex-col">
      <div className="flex-1 flex flex-col items-center justify-center p-6">
        <div className="bg-white/10 backdrop-blur-md p-8 rounded-2xl shadow-2xl w-full max-w-md border border-white/20">
          <div className="flex justify-center mb-6">
            <PackageIcon size={32} className="text-blue-400" />
          </div>
          <h1 className="text-2xl font-bold text-center mb-4 text-white">
            Selecionar Versão
          </h1>
          <p className="text-gray-300 mb-6 text-center text-sm">
            Escolha a versão da multimídia a instalar. O padrão é a mais recente.
          </p>

          {loading && (
            <div className="text-center text-gray-400 py-4">
              Carregando versões…
            </div>
          )}

          {error && (
            <div className="bg-red-900/40 border border-red-500/30 text-red-100 px-4 py-3 rounded-xl mb-4 text-sm">
              <p className="font-medium text-red-300 mb-1">
                Falha ao listar versões:
              </p>
              <p className="break-words">{error}</p>
              <button
                onClick={load}
                className="mt-3 inline-flex items-center gap-1 text-red-200 underline"
              >
                <RefreshCwIcon size={14} /> Tentar novamente
              </button>
            </div>
          )}

          {!loading && !error && (
            <select
              value={selected}
              onChange={(e) => setSelected(e.target.value)}
              className="w-full bg-gray-800 text-white border border-gray-600 rounded-xl px-4 py-3 mb-6"
            >
              <option value={LATEST_SENTINEL}>
                Última versão (recomendado)
              </option>
              {releases.map((r) => (
                <option key={r.tag} value={r.tag}>
                  {r.name}
                  {r.prerelease ? ' (pre-release)' : ''}
                </option>
              ))}
            </select>
          )}

          <div className="space-y-3">
            <button
              onClick={handleContinue}
              disabled={loading}
              className={`block w-full text-center py-4 px-6 rounded-xl font-medium transition-all duration-300 ${
                loading
                  ? 'bg-gray-600 text-gray-300 cursor-not-allowed'
                  : 'bg-blue-600 text-white hover:bg-blue-700 shadow-lg hover:shadow-blue-600/30'
              }`}
            >
              Continuar
            </button>
            <Link
              to="/install"
              className="flex items-center justify-center gap-2 w-full bg-gray-700 text-white py-3 px-4 rounded-xl hover:bg-gray-600 transition-all duration-300 border border-gray-600"
            >
              <ArrowLeftIcon size={18} />
              <span>Voltar</span>
            </Link>
          </div>
        </div>
      </div>
    </div>
  )
}
